# This flake file is community maintained
{
  description = "Jay: A Wayland compositor.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # Jay requires the latest stable version of Rust.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
      crane,
    }:
    let
      inherit (nixpkgs) lib;
      systems = lib.intersectLists lib.systems.flakeExposed lib.platforms.linux;
      forAllSystems =
        f:
        lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              overlays = [ (import rust-overlay) ];
            }
          )
        );

      jayConfigVersion = (lib.importTOML ./jay-config/Cargo.toml).package.version;

      # `jay` depends on `jay-config` as a workspace member. Building `jay`
      # against the cargoArtifacts produced while building the `jay-config`
      # package means jay-config's own compilation is reused instead of
      # happening a second time as part of jay's build.
      jayPackage =
        {
          lib,
          stdenv,
          craneLib,
          commonArgs,
          cargoArtifacts,
          autoPatchelfHook,
          installShellFiles,
          libglvnd,
          sqlite,
          vulkan-loader,
        }:
        craneLib.buildPackage (
          commonArgs
          // {
            pname = "jay";
            version = self.shortRev or self.dirtyShortRev or "unknown";

            inherit cargoArtifacts;

            nativeBuildInputs = commonArgs.nativeBuildInputs ++ [
              autoPatchelfHook
              installShellFiles
            ];

            runtimeDependencies = [
              libglvnd
              sqlite.out
              vulkan-loader
            ];

            # Jay uses https://docs.rs/dlopen-note/latest/dlopen_note/ to declare its optional runtime
            # dependencies in ELF metadata (https://uapi-group.org/specifications/specs/elf_dlopen_metadata/).
            # However, auto-patchelf fails if these dependencies are not present at compile time.
            autoPatchelfIgnoreMissingDeps = [
              "libGLESv2.so.2"
              "libEGL.so.1"
              "libsqlite3.so.0"
              "libvulkan.so.1"
            ];

            # the following tests require access to io_uring, which is disabled in the sandboxed build environment
            cargoTestExtraArgs =
              "-- "
              + lib.concatMapStringsSep " " (test: "--skip=${test}") [
                "cpu_worker::tests::cancel"
                "cpu_worker::tests::complete"
                "eventfd_cache::tests::test"
                "io_uring::ops::read_write_no_cancel::tests::cancel_in_kernel"
                "io_uring::ops::read_write_no_cancel::tests::cancel_in_userspace"
              ];

            postInstall = ''
              install -D etc/jay.portal $out/share/xdg-desktop-portal/portals/jay.portal
              install -D etc/jay-portals.conf $out/share/xdg-desktop-portal/jay-portals.conf
              install -D etc/jay.desktop $out/share/wayland-sessions/jay.desktop
            ''
            + lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
              installShellCompletion --cmd jay \
                --bash <("$out/bin/jay" generate-completion bash) \
                --zsh <("$out/bin/jay" generate-completion zsh) \
                --fish <("$out/bin/jay" generate-completion fish)
            '';

            passthru = {
              providedSessions = [ "jay" ];
            };

            meta = with lib; {
              description = "Wayland compositor written in Rust";
              homepage = "https://github.com/mahkoh/jay";
              license = licenses.gpl3;
              platforms = platforms.linux;
              mainProgram = "jay";
            };
          }
        );

      # A package usable to build shared library configurations for jay, e.g. a
      # crate with `crate-type = ["cdylib"]` that has `jay-config` as a path
      # dependency. Exposing jay-config's own cargoArtifacts lets such a config
      # crate be built with crane without recompiling jay-config or its
      # dependencies from scratch.
      jayConfigPackage =
        {
          lib,
          craneLib,
          commonArgs,
          cargoArtifacts,
        }:
        craneLib.buildPackage (
          commonArgs
          // {
            pname = "jay-config";
            version = jayConfigVersion;

            inherit cargoArtifacts;

            cargoExtraArgs = "--locked -p jay-config";
            doInstallCargoArtifacts = true;
            doCheck = false;

            meta = with lib; {
              description = "Configuration crate for the Jay compositor";
              homepage = "https://github.com/mahkoh/jay";
              license = licenses.gpl3;
              platforms = platforms.linux;
            };
          }
        );

    in
    {
      devShells = forAllSystems (pkgs: {
        default =
          let
            inherit (self.packages.${pkgs.system}) jay;
            rust = pkgs.rust-bin.stable.latest.default.override {
              extensions = [
                "rust-src"
                "clippy"
                "rustfmt"
              ];
            };
          in
          pkgs.mkShell {
            inputsFrom = [ jay ];
            packages = [ rust ];
          };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);

      packages = forAllSystems (
        pkgs:
        let
          rust = pkgs.rust-bin.stable.latest.default;
          craneLib = (crane.mkLib pkgs).overrideToolchain (_: rust);

          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.gitTracked ./.;
          };

          commonArgs = {
            inherit src;
            strictDeps = true;

            nativeBuildInputs = [ pkgs.pkgconf ];

            buildInputs = with pkgs; [
              fontconfig
              libgbm
              libinput
              pango
              udev
              xkeyboard-config
            ];
          };

          # Only the third-party dependencies of the whole workspace, built from
          # a dummy source so this derivation is unaffected by edits to any
          # crate's own code.
          cargoArtifacts = craneLib.buildDepsOnly commonArgs;

          jay-config = pkgs.callPackage jayConfigPackage {
            inherit craneLib commonArgs cargoArtifacts;
          };

          jay = pkgs.callPackage jayPackage {
            inherit craneLib commonArgs;
            cargoArtifacts = jay-config;
          };
        in
        {
          inherit jay jay-config;
          default = jay;
        }
      );

      overlays.default = final: _: { inherit (self.packages.${final.system}) jay jay-config; };
    };
}
