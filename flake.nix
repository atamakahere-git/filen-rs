{
  description = "Filen Rust SDK and CLI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-utils.url = "github:numtide/flake-utils";

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, crane, rust-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };

        # Read the nightly version from rust-toolchain.toml
        rustToolchain = pkgs.rust-bin.nightly."2025-08-14".default.override {
          extensions = [ "rust-src" "rust-analyzer" ];
        };

        # Crane lib, instantiated with our custom toolchain
        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        # Common build inputs needed for the project
        buildInputs = with pkgs; [
          # For heif-decoder native deps
          cmake
          clang
          stdenv.cc.cc.lib
        ];

        nativeBuildInputs = with pkgs; [
          # Build tools
          cmake
          pkg-config
          clang
        ];

        # Source filtering for crane
        src = craneLib.cleanCargoSource ./.;

        # Common arguments for crane
        commonArgs = {
          inherit src buildInputs nativeBuildInputs;

          # Ensure heif-decoder can find the C++ stdlib
          LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";

          # Set proper library paths
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
            pkgs.stdenv.cc.cc.lib
          ];

          # Needed for bindgen in heif-decoder
          BINDGEN_EXTRA_CLANG_ARGS = [
            "-isystem ${pkgs.libclang.lib}/lib/clang/${pkgs.libclang.version}/include"
          ];
        };

        # Build *just* the cargo dependencies, so we can reuse
        # all of that work when running in CI
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        # Build the actual crate itself, reusing the dependency artifacts
        filen-rs = craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;

          # Build the CLI binary
          cargoExtraArgs = "--bin filen-cli";

          # Additional metadata
          meta = {
            description = "Filen Rust SDK and CLI";
            homepage = "https://github.com/FilenCloudDienste/filen-rs";
            license = pkgs.lib.licenses.agpl3Only;
            mainProgram = "filen-cli";
          };
        });

      in
      {
        # `nix build`
        packages = {
          default = filen-rs;
          filen-rs = filen-rs;

          # Individual workspace members can be built if needed
          # You can add specific packages here if needed
        };

        # `nix run`
        apps.default = flake-utils.lib.mkApp {
          drv = filen-rs;
        };

        # `nix develop`
        devShells.default = pkgs.mkShell {
          inputsFrom = [ filen-rs ];

          buildInputs = buildInputs ++ (with pkgs; [
            # Rust toolchain
            rustToolchain

            # Development tools
            cargo-watch
            cargo-edit
            cargo-outdated
            cargo-audit
            cargo-tarpaulin
            bacon

            # Other useful tools
            git
          ]);

          nativeBuildInputs = nativeBuildInputs;

          # Environment variables for development
          RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";
          LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
            pkgs.stdenv.cc.cc.lib
          ];

          BINDGEN_EXTRA_CLANG_ARGS = [
            "-isystem ${pkgs.libclang.lib}/lib/clang/${pkgs.libclang.version}/include"
          ];

          shellHook = ''
            echo "🦀 Filen Rust development environment"
            echo "Rust version: $(rustc --version)"
            echo "Cargo version: $(cargo --version)"
            echo ""
            echo "Available commands:"
            echo "  cargo build    - Build the project"
            echo "  cargo test     - Run tests"
            echo "  cargo run      - Run the CLI"
            echo "  cargo watch    - Watch for changes and rebuild"
            echo "  bacon          - Background code checker"
          '';
        };

        # `nix flake check`
        checks = {
          # Build the crate as part of `nix flake check`
          inherit filen-rs;

          # Run tests
          filen-rs-tests = craneLib.cargoNextest (commonArgs // {
            inherit cargoArtifacts;
            partitions = 1;
            partitionType = "count";
          });

          # Check formatting
          filen-rs-fmt = craneLib.cargoFmt {
            inherit src;
          };

          # Check clippy
          filen-rs-clippy = craneLib.cargoClippy (commonArgs // {
            inherit cargoArtifacts;
            cargoClippyExtraArgs = "--all-targets -- --deny warnings";
          });

          # Audit dependencies
          # Commented out until we have a stable advisory-db hash
          # filen-rs-audit = craneLib.cargoAudit {
          #   inherit src;
          # };
        };
      }
    );
}
