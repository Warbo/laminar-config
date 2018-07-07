with builtins;
with { pkgs = import <nixpkgs> {}; };
with pkgs.lib;
with pkgs.nix-helpers or (import (pkgs.fetchgit {
  url    = http://chriswarbo.net/git/nix-helpers.git;
  rev    = "66f9a00";
  sha256 = "0f84hyqslzb56gwc8yrrn8s95nvdfqn0hf6c9i3cng3bsz3yk53v";
}));
with pkgs;
with rec {
  machine = with { m = if pathExists /home/user then "desktop" else "laptop"; };
            trace "Calculating jobs for '${m}'" m;

  lockScripts = name: {
    lock = wrap {
      name   = "lock-script-${name}";
      paths  = [ bash ];
      script = ''
        #!/usr/bin/env bash
        set -e
        laminarc lock "${name}"
      '';
    };
    release = wrap {
      name   = "release-script-${name}";
      paths  = [ bash ];
      script = ''
        #!/usr/bin/env bash
        set -e
        laminarc release "${name}"
      '';
    };
  };

  # Sets up a job to build the given Nix file from the given git repo
  buildNixRepo =
    {
      name,
      file ? "release.nix",
      repo ? "${repoSource}/${name}.git"
    }: {
      # Clones the required git repo to the "workspace" the first time this job
      # is run
      "${name}.init" = wrap {
        name   = "${name}.init";
        paths  = [ bash git ];
        script = ''
          #!/usr/bin/env bash
          set -e
          mkdir -p "$WORKSPACE"
          git clone "${repo}" "$WORKSPACE/${name}"
        '';
      };

      # Pull any updates before we run the job. We protect this with a lock to
      # avoid concurrent pulls
      "${name}.before" = wrap {
        name   = "${name}.before";
        paths  = [ bash git ];
        script = ''
          #!/usr/bin/env bash
          set -e
          laminarc lock "${name}-git"
            pushd "$WORKSPACE/${name}"
              # We could parameterise this by revision in the future
              git pull --all
            popd
            # Make a copy to avoid interference (use hardlinks for speed)
            cp -al "$WORKSPACE/${name}" "${name}"
          laminarc release "${name}-git"
        '';
      };

      # The main job script
      "${name}.run" = wrap {
        name   = "${name}.run";
        paths  = [ bash nix ];
        vars   = withNix {};
        script = ''
          #!/usr/bin/env bash
          set -e
          cd "${name}"
          nix-build --show-trace "${file}"
        '';
      };
  };

  # Projects which provide release.nix file defining their build products
  simpleNixRepos = genAttrs [
    "benchmark-runner" "bucketing-algorithms" "chriswarbo-net" "general-tests"
    "haskell-te" "isaplanner-tip" "ml4pg" "music-scripts" "nix-config"
    "nix-eval" "nix-helpers" "nix-lint" "panhandle" "panpipe"
    "theory-exploration-benchmarks" "warbo-packages" "warbo-utilities" "writing"
  ] (name: buildNixRepo { inherit name; });

  # Things which only make sense on laptop, e.g. using non-git resources
  laptopOverrides = if machine != "laptop" then {} else
    with { testLocks = lockScripts "test-runner"; };
    {
      test-runner = {
        "test-runner.after"  = testLocks.release;
        "test-runner.before" = testLocks.lock;
        "test-runner.run"    = wrap {
          name   = "test-runner.run";
          paths  = [ bash nix ];
          vars   = withNix {};
          script = ''
            #!/usr/bin/env bash
            exec /home/chris/System/Tests/run
          '';
        };
      };
    };

  jobs = simpleNixRepos // laptopOverrides;
};
attrsToDirs { jobs = fold mergeAttrs {} (attrValues jobs); }
