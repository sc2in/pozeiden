{
  description = "pozeiden — pure-Zig mermaid diagram renderer";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1.964459.tar.gz";
    zig2nix.url = "https://flakehub.com/f/Cloudef/zig2nix/0.1.885.tar.gz";
  };

  outputs = {
    self,
    nixpkgs,
    zig2nix,
    ...
  }: let
    supportedSystems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems f;
    version = self.shortRev or self.dirtyShortRev or "dev";
  in {
    packages = forAllSystems (
      system: let
        env = zig2nix.outputs.zig-env.${system} {zig = nixpkgs.legacyPackages.${system}.zig;};
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        # Only hash files that affect the compiled output.
        # grammars/ is embedded at compile time via @embedFile — must be included.
        buildSrc = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./build.zig
            ./build.zig.zon
            ./build.zig.zon2json-lock
            ./src
            ./grammars
            ./playground
          ];
        };

        mkPozeiden = optimize:
          env.package {
            pname = "pozeiden";
            inherit version;
            src = buildSrc;
            zigBuildFlags =
              lib.optional (optimize != null) "-Doptimize=${optimize}";
            zigBuildZonLock = ./build.zig.zon2json-lock;
          };

        withDesc = drv: desc:
          drv.overrideAttrs (old: {
            meta = (old.meta or {}) // {description = desc;};
          });
      in {
        default = withDesc (mkPozeiden null) "pozeiden — mermaid → SVG renderer";
        pozeiden-safe = withDesc (mkPozeiden "ReleaseSafe") "pozeiden (ReleaseSafe)";
        pozeiden-small = withDesc (mkPozeiden "ReleaseSmall") "pozeiden (ReleaseSmall)";
        pozeiden-fast = withDesc (mkPozeiden "ReleaseFast") "pozeiden (ReleaseFast)";
      }
    );

    # `nix flake check` / omnix ci — runs `zig build test`
    checks = forAllSystems (system: {
      test = self.packages.${system}.default.overrideAttrs (old: {
        pname = "pozeiden-test";
        buildPhase = "zig build test";
        installPhase = "touch $out";
        meta = (old.meta or {}) // {description = "Run zig build test";};
      });
    });

    devShells = forAllSystems (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
        env = zig2nix.outputs.zig-env.${system} {zig = pkgs.zig;};

        fuzz = pkgs.writeShellApplication {
          name = "fuzz";
          meta.description = "Run coverage-guided fuzz tests with the Zig web UI (optional port argument, default 8080)";
          text = ''
            PORT="''${1:-8080}"
            echo "▸ Starting fuzzer — web UI at http://127.0.0.1:$PORT"
            zig build test --fuzz --port "$PORT"
          '';
        };
      in {
        default = env.mkShell {
          nativeBuildInputs = [
            pkgs.zls
            pkgs.bash
            fuzz
            (pkgs.writeShellScriptBin "update-zon" ''
              set -euo pipefail
              if ! command -v zig &>/dev/null; then
                echo "zig is not installed or not in PATH" >&2
                exit 1
              fi
              echo "Updating build.zig.zon dependencies..."
              zig fetch --save .
              echo "build.zig.zon updated."
            '')
          ];

          shellHook = ''
            export ZIG_GLOBAL_CACHE_DIR=.zig-cache
            echo "To update Zig dependencies, run: update-zon"
            echo "To run the fuzzer, run: fuzz [port]  (default port: 8080)"
            if [ -f build.zig.zon ]; then
              if [ ! -f build.zig.zon2json-lock ] || [ build.zig.zon -nt build.zig.zon2json-lock ]; then
                echo "zig2nix: regenerating build.zig.zon2json-lock..."
                zig2nix zon2lock
              fi
            fi
          '';
        };
      }
    );

    apps = forAllSystems (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        # `nix run .` — render a diagram from stdin
        default = {
          type = "app";
          program = "${self.packages.${system}.pozeiden-safe}/bin/pozeiden";
          meta.description = "Render a mermaid diagram to SVG (reads stdin, writes stdout)";
        };

        # `nix run .#playground [port]` — build WASM + open live playground
        playground = let
          app = pkgs.writeShellApplication {
            name = "pozeiden-playground";
            meta.description = "Build the WASM module and serve the live playground (optional port, default 8080)";
            runtimeInputs = [pkgs.git pkgs.python3];
            text = ''
              cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
              echo "▸ Building playground…"
              zig build playground
              PORT="''${1:-8080}"
              echo "✓ Open http://localhost:$PORT in your browser"
              python3 -m http.server "$PORT" -d zig-out/playground
            '';
          };
        in {
          type = "app";
          program = "${app}/bin/pozeiden-playground";
          meta.description = "Build the WASM module and serve the live playground (optional port, default 8080)";
        };
      }
    );
  };
}
