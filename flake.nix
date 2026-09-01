# Nix flake for antirez/ds4 ("DwarfStar"), the native inference engine for
# DeepSeek V4 Flash. This only builds the ROCm ("Strix Halo", gfx1151) variant;
# ds4 is ROCm-only (no Vulkan/CUDA backend), so the ROCm build is the default.
#
# Like ggml-org/llama.cpp's flake, this exposes the build as
# `packages.<system>.<name>` so it can be consumed as a plain flake input:
#
#   inputs.ds4.url = "github:kalvinarts/ds4";
#   # ...
#   pkgs = import nixpkgs { system = "..."; overlays = [ ds4.overlays.default ]; };
#   pkgs.ds4            # all five binaries (ds4, ds4-server, ds4-bench, ...)
#
# For the Strix Halo host this is used as `pkgs.ds4` directly (see the dotfiles
# home wrapper), or `ds4.packages.<system>.rocm` when pulled in as a flake.
{
  description = "Native inference engine for DeepSeek V4 Flash (antirez/ds4, \"DwarfStar\"); ROCm build for AMD Strix Halo (gfx1151).";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      nixpkgs,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # ds4's ROCm backend targets x86_64-linux on the Strix Halo APUs.
      systems = [ "x86_64-linux" ];

      perSystem =
        {
          config,
          system,
          pkgs,
          lib,
          ...
        }:
        let
          # ROCm libraries ds4 links against. These are pulled prebuilt from
          # the binary cache; we reference pkgs.rocmPackages.* directly and
          # never .override them, so their cached derivation hashes are
          # preserved (an override would miss the cache and force a full ROCm
          # rebuild).
          #
          # `clr` subsumes the old `hip`, `opencl-runtime` and `rocclr`: it
          # provides the `hipcc` driver, the `<hip/*>` headers and the
          # `libamdhip64` runtime, so it replaces the standalone `hipcc`.
          # `hipblas-common` ships `hipblas-common.h`, which `hipblas.h`
          # includes. All are prebuilt and only linked against.
          rocmPkgs = with pkgs.rocmPackages; [
            clr
            hipblas
            hipblas-common
            hipblaslt
            rocblas
            rocprim
            rocwmma
            hipcub
          ];

          # ds4 includes `<cub/block/...>` but nixpkgs installs hipCUB under
          # `<hipcub>/...`, so provide a `cub/` alias so that include resolves.
          cubAlias = pkgs.runCommand "ds4-cub-include" { } ''
            mkdir -p "$out/include"
            ln -s ${pkgs.rocmPackages.hipcub}/include/hipcub "$out/include/cub"
          '';

          # Include/lib dirs for every ROCm package (plus the cub alias).
          rocmIncludes = lib.concatStringsSep " " (map (p: "-I${p}/include") (rocmPkgs ++ [ cubAlias ]));
          rocmLibPaths = lib.concatStringsSep " " (map (p: "-L${p}/lib") rocmPkgs);

          # ROCm Strix Halo (gfx1151) build of every ds4 binary. Only ds4's
          # own sources are compiled here; the ROCm libraries stay prebuilt
          # and are only linked against.
          #
          # The Makefile ignores the usual CPPFLAGS/LDFLAGS hooks, so the store
          # paths go into the variables it *does* expand: CFLAGS (the .c
          # files), ROCM_CFLAGS (the .cu files and links) and ROCM_LDLIBS
          # (linking). We set those in the build *environment* rather than via
          # makeFlags for two reasons:
          #
          #   * stdenv expands $makeFlags unquoted, so a value with spaces would
          #     be word-split and make would read a bare "-I/nix/..." as an
          #     invalid option.
          #   * the Makefile defines ROCM_CFLAGS/ROCM_LDLIBS with `?=`. A
          #     command-line `VAR+=` is read *before* the Makefile and pre-sets
          #     the variable, defeating that default — which would drop
          #     --offload-arch=gfx1151, -D__HIP_PLATFORM_AMD__ and the
          #     -lhipblas* link flags (compiling for the wrong arch, gfx906).
          #     Setting the complete value in the environment replaces the
          #     default cleanly.
          ds4 = pkgs.stdenv.mkDerivation {
            pname = "ds4";
            version = "0.1.0-main";
            src = ./.;

            nativeBuildInputs = [
              pkgs.pkg-config
              pkgs.rocmPackages.clr
            ];
            buildInputs = rocmPkgs;

            enableParallelBuilding = true;

            # Note: no `dontInstall` here — a custom installPhase must not be
            # suppressed, or $out is never populated and the derivation fails
            # to produce its `out` path.
            buildPhase = ''
              export CFLAGS="-O3 -ffast-math -g -march=native -Wall -Wextra -std=c99 -D_GNU_SOURCE -fno-finite-math-only ${rocmIncludes}"
              export ROCM_CFLAGS="-O3 -ffast-math -g -fno-finite-math-only -pthread -D__HIP_PLATFORM_AMD__ -Wno-unused-command-line-argument --offload-arch=gfx1151 ${rocmIncludes}"
              export ROCM_LDLIBS="-lm -pthread -lhipblas -lhipblaslt -lrocblas ${rocmLibPaths}"
              make -j$NIX_BUILD_CORES strix-halo
            '';

            # The Makefile drops its binaries in the source tree; install
            # them into the store instead.
            installPhase = ''
              install -Dm755 ds4-server $out/bin/ds4-server
              install -Dm755 ds4 $out/bin/ds4
              install -Dm755 ds4-bench $out/bin/ds4-bench
              install -Dm755 ds4-agent $out/bin/ds4-agent
              install -Dm755 ds4-eval $out/bin/ds4-eval
            '';
          };
        in
        {
          # Reproducible formatting with `nix fmt`, matching the rest of the
          # repo (llama.cpp uses nixfmt-rfc-style too).
          formatter = pkgs.nixfmt;

          # `default` is the ROCm Strix Halo build; `ds4` and `rocm` are
          # convenience aliases with the same derivation.
          packages.default = ds4;
          packages.ds4 = ds4;
          packages.rocm = ds4;

          # Built by `nix flake check` (and CI): just verifies the derivation
          # compiles. Runtime tests need a GPU + model, so they are skipped.
          checks = {
            inherit (config.packages) default;
          };
        };
    };
}
