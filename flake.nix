{
  description = "pozeiden — pure-Zig mermaid diagram renderer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/e7713b176c927fdab81a18801682bd2606491b0a";
    zig2nix.url = "https://flakehub.com/f/Cloudef/zig2nix/0.1.990.tar.gz";
    zigmark.url = "github:sc2in/zigmark";
    zigmark.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    self,
    nixpkgs,
    zig2nix,
    zigmark,
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
            ./examples
            ./include
            ./golden_test.zig
            ./tests
          ];
        };

        # zon2lock truncates its destination in place before it starts
        # fetching, so an interrupted regeneration leaves a 0-byte lock
        # behind; zig2nix then imports an empty Nix file and dies with a
        # cryptic "syntax error, unexpected end of file". Fail evaluation
        # early with an actionable message instead.
        zonLock =
          if builtins.readFile ./build.zig.zon2json-lock == ""
          then throw "build.zig.zon2json-lock is empty — regenerate it with `update-zon` inside `nix develop` and commit the result"
          else ./build.zig.zon2json-lock;

        mkPozeiden = optimize:
          env.package {
            pname = "pozeiden";
            inherit version;
            src = buildSrc;
            zigBuildFlags =
              lib.optional (optimize != null) "-Doptimize=${optimize}";
            zigBuildZonLock = zonLock;
          };

        withDesc = drv: desc:
          drv.overrideAttrs (old: {
            meta = (old.meta or {}) // {description = desc;};
          });
      in let
        defaultPkg = withDesc (mkPozeiden null) "pozeiden — mermaid → SVG renderer";
      in {
        default = defaultPkg;
        pozeiden-safe = withDesc (mkPozeiden "ReleaseSafe") "pozeiden (ReleaseSafe)";
        pozeiden-small = withDesc (mkPozeiden "ReleaseSmall") "pozeiden (ReleaseSmall)";
        pozeiden-fast = withDesc (mkPozeiden "ReleaseFast") "pozeiden (ReleaseFast)";
        site = defaultPkg.overrideAttrs (_old: {
          pname = "pozeiden-site";
          buildPhase = "zig build site";
          installPhase = ''
            mkdir -p $out
            cp -r zig-out/site/. $out/
          '';
          meta.description = "Pozeiden static site (playground + docs)";
        });
      }
    );

    # `nix flake check` / omnix ci — build/test gates run on every PR.
    checks = forAllSystems (system: {
      test = self.packages.${system}.default.overrideAttrs (old: {
        pname = "pozeiden-test";
        buildPhase = "zig build test";
        installPhase = "touch $out";
        meta = (old.meta or {}) // {description = "Run zig build test (Debug)";};
      });
      # Exercise the shipped optimisation path with safety checks on, so bugs
      # that only appear under release optimisation are caught in CI.
      test-release-safe = self.packages.${system}.default.overrideAttrs (old: {
        pname = "pozeiden-test-release-safe";
        buildPhase = "zig build test -Doptimize=ReleaseSafe";
        installPhase = "touch $out";
        meta = (old.meta or {}) // {description = "Run zig build test (ReleaseSafe)";};
      });
      # Smoke-run the fuzz targets once each (no coverage-guided search) so the
      # byte-in render/detect paths are exercised on every PR.
      fuzz-smoke = self.packages.${system}.default.overrideAttrs (old: {
        pname = "pozeiden-fuzz-smoke";
        buildPhase = "zig build fuzz";
        installPhase = "touch $out";
        meta = (old.meta or {}) // {description = "Smoke-run the fuzz targets";};
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
            (pkgs.writeShellApplication {
              name = "update-zon";
              runtimeInputs = [pkgs.git pkgs.jq];
              meta.description = "Regenerate build.zig.zon2json-lock atomically, validating the result";
              text = ''
                cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
                if ! command -v zig &>/dev/null; then
                  echo "zig is not installed or not in PATH" >&2
                  exit 1
                fi
                echo "Regenerating build.zig.zon2json-lock..."
                # zon2lock truncates its destination before it starts
                # fetching, so writing straight to the real lock risks
                # leaving a 0-byte file behind on failure or ^C. Generate
                # into a temp file, validate, then move into place.
                tmp="$(mktemp .build.zig.zon2json-lock.XXXXXX)"
                trap 'rm -f "$tmp"' EXIT
                env -u ZIG_GLOBAL_CACHE_DIR zig2nix zon2lock build.zig.zon "$tmp"
                if ! jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
                  echo "error: generated lock is empty or invalid JSON; keeping existing build.zig.zon2json-lock" >&2
                  exit 1
                fi
                mv -f "$tmp" build.zig.zon2json-lock
                echo "build.zig.zon2json-lock updated."
              '';
            })
          ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.mermaid-cli
            # bench compares against mmdc; gracefully skipped when not in PATH
          ];

          shellHook = ''
            export ZIG_GLOBAL_CACHE_DIR=.zig-cache

            # Install the release-tag CHANGELOG guard. Kept in .githooks/ so
            # it is version-controlled; the release workflow enforces the same
            # rule as an un-bypassable backstop.
            hooks_dir="$(git rev-parse --git-path hooks 2>/dev/null || true)"
            if [ -n "$hooks_dir" ] && [ -f .githooks/pre-push ]; then
              mkdir -p "$hooks_dir"
              cp -f .githooks/pre-push "$hooks_dir/pre-push"
              chmod +x "$hooks_dir/pre-push"
            fi

            echo "To update Zig dependencies, run: update-zon"
            echo "To run the fuzzer, run: fuzz [port]  (default port: 8080)"
            if [ -f build.zig.zon ]; then
              # -s (not -f): a 0-byte lock left behind by an interrupted
              # regeneration is newer than build.zig.zon, so a plain mtime
              # check would consider it fresh forever.
              if [ ! -s build.zig.zon2json-lock ] || [ build.zig.zon -nt build.zig.zon2json-lock ]; then
                update-zon
              fi
            fi
          '';
        };
      }
    );

    apps = forAllSystems (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
      in {
        # `nix run .#bench` — run benchmarks and splice results into README.md
        bench = let
          benchApp = pkgs.writeShellApplication {
            name = "pozeiden-bench";
            runtimeInputs = [
              pkgs.zig
              pkgs.git
              zigmark.packages.${system}.default
            ] ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.mermaid-cli ];
            text = ''
              REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
              cd "$REPO"
              NEW=$(mktemp /tmp/bench-section-XXXXXX.md)
              trap 'rm -f "$NEW"' EXIT
              echo "▸ Building and running benchmarks…"
              {
                printf '_Last updated: %s - run: nix run .#bench\n\n' \
                  "$(date -u '+%Y-%m-%d')"
                zig build bench
              } > "$NEW"
              echo "▸ Updating README.md…"
              zigmark -f normalize \
                --section-start bench-start \
                --section-end   bench-end   \
                "$REPO/README.md"           \
                -o "$REPO/README.md"        \
                < "$NEW"
              echo "✓ README.md updated."
            '';
          };
        in {
          type = "app";
          program = "${benchApp}/bin/pozeiden-bench";
        };

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

        # `nix run .#bump -- <version|patch|minor|major>` performs the manual
        # pre-release steps in one shot: bumps the version in build.zig.zon,
        # rolls the CHANGELOG `[Unreleased]` section into a dated release
        # section, and commits. Pushing the tag is left to you; the release
        # workflow then builds artifacts and publishes.
        bump = let
          bump-app = pkgs.writeShellApplication {
            name = "pozeiden-bump";
            runtimeInputs = with pkgs; [coreutils gnused gawk git];
            meta.description = "Bump version in build.zig.zon and roll the CHANGELOG";
            text = ''
              dry=0
              commit=1
              arg=""
              for a in "$@"; do
                case "$a" in
                  --dry-run) dry=1 ;;
                  --no-commit) commit=0 ;;
                  -h | --help)
                    echo "usage: nix run .#bump -- <version|patch|minor|major> [--dry-run] [--no-commit]"
                    exit 0
                    ;;
                  *) arg="$a" ;;
                esac
              done

              if [ -z "$arg" ]; then
                echo "usage: nix run .#bump -- <version|patch|minor|major> [--dry-run] [--no-commit]" >&2
                exit 1
              fi

              cur=$(sed -nE 's/^[[:space:]]*\.version = "([^"]+)",/\1/p' build.zig.zon | head -n1)
              if [ -z "$cur" ]; then
                echo "error: could not read current version from build.zig.zon" >&2
                exit 1
              fi

              case "$arg" in
                major | minor | patch)
                  IFS=. read -r ma mi pa <<< "$cur"
                  case "$arg" in
                    major)
                      ma=$((ma + 1))
                      mi=0
                      pa=0
                      ;;
                    minor)
                      mi=$((mi + 1))
                      pa=0
                      ;;
                    patch) pa=$((pa + 1)) ;;
                  esac
                  new="$ma.$mi.$pa"
                  ;;
                *) new="$arg" ;;
              esac

              if ! [[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "error: invalid version '$new' (expected X.Y.Z or patch|minor|major)" >&2
                exit 1
              fi

              today=$(date +%F)
              echo "Release: $cur -> $new ($today)"

              if [ "$dry" = 1 ]; then
                echo "[dry-run] would update:"
                echo "  build.zig.zon  .version = \"$new\""
                echo "  CHANGELOG.md   roll [Unreleased] into [$new] - $today"
                exit 0
              fi

              sed -i -E "s/^([[:space:]]*\.version = )\"[^\"]+\",/\1\"$new\",/" build.zig.zon
              awk -v ver="$new" -v dt="$today" '
                !done && /^## \[Unreleased\]/ {
                  print "## [Unreleased]";
                  print "";
                  print "## [" ver "] - " dt;
                  done = 1;
                  next
                }
                { print }
              ' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md

              echo "Updated build.zig.zon, CHANGELOG.md"

              if [ "$commit" = 1 ]; then
                git add build.zig.zon CHANGELOG.md
                git commit -m "chore: release $new"
                echo ""
                echo "Committed 'chore: release $new'. Publish with:"
                echo "  git tag v$new && git push origin HEAD v$new"
              else
                echo ""
                echo "Files edited (not committed). Then:"
                echo "  git add build.zig.zon CHANGELOG.md && git commit -m 'chore: release $new'"
                echo "  git tag v$new && git push origin HEAD v$new"
              fi
            '';
          };
        in {
          type = "app";
          program = "${bump-app}/bin/pozeiden-bump";
          meta.description = "Bump version in build.zig.zon and roll the CHANGELOG for a release";
        };
      }
    );
  };
}
