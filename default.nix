with builtins;
with rec {
  pkgs    = import <nixpkgs> {};
  helpers = pkgs.fetchgit {
    url    = http://chriswarbo.net/git/nix-helpers.git;
    rev    = "72d9d88";
    sha256 = "1kggqr07dz2widv895wp8g1x314lqg19p67nzr3b97pg97amhjsi";
  };
  packages = pkgs.fetchgit {
    url    = http://chriswarbo.net/git/warbo-packages.git;
    rev    = "773c523";
    sha256 = "0q89iczdj1gw2s4facpd23kh31w2xfvkdzcb0njwzg2d7pysmpni";
  };
  configuredPkgs = import <nixpkgs> {
    overlays = [ (import  "${helpers}/overlay.nix")
                 (import "${packages}/overlay.nix") ];
  };
  benchmark-runner = pkgs.fetchgit {
    url    = http://chriswarbo.net/git/benchmark-runner.git;
    rev    = "4113681";
    sha256 = "077mn2krrzfnfh30qsg4kyy4x0ahsyqqhsx5nqan0v9nx78pmpzq";
  };
};
with configuredPkgs;
with lib;
with rec {
  machine = with { m = if pathExists /home/user then "desktop" else "laptop"; };
            trace "Calculating jobs for '${m}'" m;

  repoSource = pkgs.repoSource or http://chriswarbo.net/git;

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

  gitScripts = { name, repo }: {
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

    # Pull any updates before we run the job. We use a job-specific lock to
    # avoid concurrent pulls of the same repo, and a node-specific lock to
    # avoid running concurrently with a benchmarking job.
    "${name}.before" = wrap {
      name   = "${name}.before";
      paths  = [ bash git ];
      script = ''
        #!/usr/bin/env bash
        set -e
        laminarc lock "${name}-git"

        function cleanup {
          laminarc release "${name}-git"
        }
        trap cleanup EXIT

        pushd "$WORKSPACE/${name}"
          # We could parameterise this by revision in the future
          git pull --all
        popd
        # Make a copy to avoid interference (use hardlinks for speed)
        cp -al "$WORKSPACE/${name}" "${name}"
      '';
    };
  };

  # Sets up a job to build the given Nix file from the given git repo
  buildNixRepo =
    {
      name,
      file ? "release.nix",
      repo ? "${repoSource}/${name}.git"
    }: gitScripts { inherit name repo; }  // {
      # The main job script
      "${name}.run" = wrap {
        name   = "${name}.run";
        paths  = [ bash nix utillinux ];
        vars   = withNix {
          ATTRS = ''(with import ${helpers};
                     drvPathsIn (import (./. + "/${file}")))'';
          runner = writeScript "${name}-runner.sh" ''
            #!/usr/bin/env bash
            set -e
            cd "${name}"
            echo "Finding derivations" 1>&2
            DRVPATHS=$(nix eval --show-trace --raw "$ATTRS")
            echo "Building derivations" 1>&2
            COUNT=0
            FAILS=0
            while read -r PAIR
            do
              COUNT=$(( COUNT + 1 ))
              ATTR=$(echo "$PAIR" | cut -f1)
               DRV=$(echo "$PAIR" | cut -f2)
              echo "Building $ATTR" 1>&2
              nix-store --show-trace --realise "$DRV" || FAILS=$(( FAILS + 1 ))
            done < <(echo "$DRVPATHS")
            if [[ "$FAILS" -eq 0 ]]
            then
              echo "All $COUNT built successfully" 1>&2
            else
              printf '%s/%s builds failed\n' "$FAILS" "$COUNT" 1>&2
              exit 1
            fi
          '';
        };
        script = ''
          #!/usr/bin/env bash
          set -e
          echo "Waiting for read lock on $BENCHMARK_LOCK" 1>&2
          flock -s "$BENCHMARK_LOCK" -c "$runner"
          ${if elem name benchmarkRepos
               then "laminarc queue 'benchmark-${name}'"
               else ""}
        '';
      };
    };

  # Projects which provide release.nix file defining their build products
  simpleNixRepos = genAttrs [
    "asv-nix" "benchmark-runner" "bucketing-algorithms" "chriswarbo-net"
    "general-tests" "haskell-te" "isaplanner-tip" "ml4pg" "music-scripts"
    "nix-config" "nix-eval" "nix-helpers" "nix-lint" "panhandle" "panpipe"
    "theory-exploration-benchmarks" "warbo-packages" "warbo-utilities" "writing"
  ] (name: buildNixRepo { inherit name; });

  buildBenchmarkRepo =
    {
      name,
      repo     ? "${repoSource}/${name}.git",
      asv-path ? ".asv"  # Relative path to results of asv
    }:
    gitScripts { inherit repo; name = "benchmark-${name}"; } // {
      # The main job script, protected by flock to prevent concurrency
      "benchmark-${name}.run" = wrap {
        name  = "benchmark-${name}.run";
        paths = [ bash gnutar lzip utillinux ];
        vars  = {
          BENCHMARK_IN_PLACE = "1";  # Don't copy, cache, etc.
          runner = import "${benchmark-runner}/runner.nix" configuredPkgs;
        };
        script = ''
          #!/usr/bin/env bash
          set -e
          echo "Setting up" 1>&2
          export HOME="$PWD/home"
          mkdir -p "$HOME"

          export dir="$WORKSPACE/benchmark-${name}"
          cd "$dir"

          echo "Waiting for exclusive lock on $BENCHMARK_LOCK" 1>&2
          flock "$BENCHMARK_LOCK" -c "$runner"

          echo "Storing results" 1>&2
          cd "${asv-path}"
          tar cf "$ARCHIVE/results.tar.lz" --lzip results
          tar cf "$ARCHIVE/html.tar.lz"    --lzip html
        '';
      };
    };

  # Projects which provide an asv.conf.json file defining a benchmark suite
  # We handle these separately to normal builds since they should never run
  # concurrently with any other job, since that would interfere with timings.
  benchmarkRepos    = [ "bucketing-algorithms" "haskell-te" "isaplanner-tip"
                        "theory-exploration-benchmarks" ];
  benchmarkRepoJobs = fold
    (name: rest: rest // {
      "benchmark-${name}" = buildBenchmarkRepo { inherit name; };
    })
    {}
    benchmarkRepos;

  # Things which only make sense on laptop, e.g. using non-git resources
  laptopOverrides = if machine != "laptop" then {} else
    with { testLocks = lockScripts "test-runner"; };
    {
      test-runner = {
        "test-runner.after"  = testLocks.release;
        "test-runner.before" = testLocks.lock;
        "test-runner.run"    = wrap {
          name   = "test-runner.run";
          paths  = [ bash utillinux ] ++ (withNix {}).buildInputs;
          vars   = withNix {};
          script = ''
            #!/usr/bin/env bash
            flock -s "$BENCHMARK_LOCK" -c /home/chris/System/Tests/run
          '';
        };
      };
    };

  jobs = {
    jobs = fold mergeAttrs {}
      (attrValues (simpleNixRepos // benchmarkRepoJobs // laptopOverrides));
  };

  extra =
    with {
      attrsToKeyVal = s: concatStringsSep "\n"
                           (mapAttrsToList (k: v: "${k}=${v}") s);
    };
    if machine == "laptop"
       then {
         nodes = {
           "laptop.conf" = writeScript "laptop.conf" ''
             EXECUTORS=1
           '';
         };
       }
       else {
         env = writeScript "env" (attrsToKeyVal {
           BENCHMARK_LOCK = "/tmp/benchmark-lock";
         });
       };

  combined = attrsToDirs (jobs // extra);

  checks = {
    everythingFlocked = runCommand "everything-flocked" { inherit combined; } ''
      echo "Checking that everything uses flock" 1>&2
      for J in "$combined/jobs"/*.run
      do
        # Delve into wrappers to find the real script
        JOB="$J"
        while grep '^exec .*extraFlagsArray' < "$JOB" > /dev/null
        do
          JOB=$(grep -o '^exec [^ ]*' < "$JOB" | head -n1 | cut -d ' ' -f2)
        done

        grep 'flock' < "$JOB" > /dev/null || {
          echo "'$J' doesn't call flock, so may interfere with benchmarks" 1>&2
          exit 1
        }
      done
      mkdir "$out"
    '';
  };
};
withDeps (attrValues checks) combined
