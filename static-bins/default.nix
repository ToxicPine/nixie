{ nixpkgs     ? <nixpkgs>
  # Nixpkgs import (from flake)

, nix-source  ? builtins.getFlake "github:nixos/nix/2.35.2"
  # Nix packages source

, fakedir     ? builtins.fetchGit "https://github.com/thesola10/fakedir"
  # libfakedir import (from flake)

, pkgs        ? import nixpkgs {}
  # Nixpkgs evaluated set

, libfakedir  ? pkgs.callPackage fakedir
  # libfakedir evaluated package

, ... }:

let
  builtSystems = [
    "x86_64-linux"
    "aarch64-linux"

    "x86_64-darwin"
    "aarch64-darwin"
  ];
  systemsPkgs =
    map (s:
      import nixpkgs { localSystem = s; }
    ) builtSystems;

  nixPackage = r:
    if !r.stdenv.isDarwin then nix-source.packages.${r.system}.nix-cli-static
    else let
      nixPkgs = import nix-source.inputs.nixpkgs {
        system = r.system;
        overlays = [ nix-source.overlays.internal ];
      };
      # Apple iconv provides Git's UTF-8-MAC support; libpsl needs GNU iconv.
      # Their version globals collide when both libraries are linked statically.
      iconv = nixPkgs.pkgsStatic.libiconvReal.overrideAttrs (old: {
        env = (old.env or {}) // {
          NIX_CFLAGS_COMPILE = "-D_libiconv_version=_gnu_libiconv_version";
        };
      });
      components = nixPkgs.pkgsStatic.nixComponents2.overrideScope (final: prev: {
        # Darwin has no BusyBox for the optional embedded sandbox shell.
        nix-store = (prev.nix-store.override {
          embeddedSandboxShell = false;
        }).overrideAttrs (old: {
          # pkgsStatic calls this CPU arm64; Nix's system name is aarch64.
          postPatch = (old.postPatch or "") + ''
            substituteInPlace nix-meson-build-support/default-system-cpu/meson.build \
              --replace-fail "'x86' : 'i686'" "'x86' : 'i686', 'arm64' : 'aarch64'"
          '';
        });
      });
    in
      (components.nix-cli.override {
        # Both mimalloc and lowdown define reallocarray on Darwin.
        withMimalloc = false;
      }).overrideAttrs (old: {
        env = (old.env or {}) // {
          # aws-c-io's static library uses Apple's Network framework.
          NIX_LDFLAGS = "-framework Network ${iconv}/lib/libiconv.a";
        };
      });
in
pkgs.stdenv.mkDerivation {
  name = "nix-static-binaries";
  src = pkgs.emptyDirectory;

  installPhase =
    let
      sys = r: r.stdenv.hostPlatform.uname.system;
      cpu = r: r.stdenv.hostPlatform.uname.processor;
    in (builtins.foldl'
      (l: r: "${l}; cp ${nixPackage r}/bin/nix $out/nix.${sys r}.${cpu r}")
      "mkdir -p $out"
      systemsPkgs)
    + '';
      cp ${libfakedir}/lib/libfakedir.dylib $out/libfakedir.dylib
      ls $out > $out/filelist
    '';
} // builtins.foldl'
  (l: r: l // { "${r.system}-nix-static" = nixPackage r; })
  { fakedir = libfakedir; } systemsPkgs
