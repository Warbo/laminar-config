with builtins;
with rec {
  pkgs    = import <nixpkgs> {};
  helpers = pkgs.fetchgit {
    url    = http://chriswarbo.net/git/nix-helpers.git;
    rev    = "8148130";
    sha256 = "1yfl361il9bxg8982qk05x3dwfgy87q8dar01q46yg7nr9mi8nza";
  };
  packages = pkgs.fetchgit {
    url    = http://chriswarbo.net/git/warbo-packages.git;
    rev    = "57165a5";
    sha256 = "1sgd595hf3jdz0hznkhzzw2nszdnkviwqxims7bzaf5sg5rm5pfi";
  };
};
with pkgs.lib;
with { inherit (import packages) asv-nix; };
with import helpers;
with pkgs;
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
        pushd "$WORKSPACE/${name}"
          # We could parameterise this by revision in the future
          git pull --all
        popd
        # Make a copy to avoid interference (use hardlinks for speed)
        cp -al "$WORKSPACE/${name}" "${name}"
        laminarc release "${name}-git"
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
          mkdir -p "/tmp/benchmark-locks"
          flock -s "/tmp/benchmark-locks/$NODE" -c "$runner"
          ${if elem name benchmarkRepos
               then ''
                 echo "Queueing benchmark run" 1>&2
                 LAMINAR_REASON="Successful build" \
                   laminarc queue benchmark-${name}''
               else ""}
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

  buildBenchmarkRepo =
    {
      name,
      repo ? "${repoSource}/${name}.git"
    }:
    gitScripts { inherit repo; name = "benchmark-${name}"; } // {
      # The main job script, protected by flock to prevent concurrency
      "benchmark-${name}.run" = wrap {
        name   = "benchmark-${name}.run";
        paths  = [ bash fail git (python.withPackages (p: [ asv-nix ]))
                   utillinux ] ++ (withNix {}).buildInputs;
        vars   = withNix {
          GIT_SSL_CAINFO = "${cacert}/etc/ssl/certs/ca-bundle.crt";
          runner = writeScript "${name}-runner.sh" ''
            #!/usr/bin/env bash
            set -e

            function runBenchmarks {
              echo "Running asv on range $1" 1>&2
              TOO_FEW_MSG="unknown revision or path not in the working tree"
              if O=$(asv run --show-stderr --machine dummy "$1" 2>&1 |
                     tee >(cat 1>&2))
              then
                # Despite asv exiting successfully, we might have still hit a
                # git rev-parse failure
                echo "$O" | grep 'asv.util.ProcessError:' > /dev/null ||
                  return 0
                echo "Spotted ProcessError from asv run, investigating..." 1>&2

                echo "$O" | grep "$TOO_FEW_MSG" > /dev/null ||
                  fail "Don't know how to handle this error, aborting"
                echo "We asked for too many commits, going to retry" 1>&2
              fi

              # Handle failures based on their error messages: some are benign
              if echo "$O" | grep 'No commit hashes selected' > /dev/null
              then
                # This happens when everything's already in the cache
                echo "No commits needed benchmarking, so asv run bailed out" 1>&2
              fi
              if echo "$O" | grep "$TOO_FEW_MSG" > /dev/null
              then
                echo "Asked to benchmark '$commitCount' commits, but" 1>&2
                echo "there aren't that many on the branch. Retrying" 2>&2
                echo "without limit."                                 1>&2
                runBenchmarks "HEAD" || fail "Retry attempt failed"
                return 0
              fi

              fail "asv run failed, and it wasn't for lack of commits"
            }

            cd "benchmark-${name}"
            runBenchmarks
          '';
        };
        script = ''
          # Take an exclusive lock for the duration of the benchmark
          mkdir -p "/tmp/benchmark-locks"
          flock    "/tmp/benchmark-locks/$NODE" -c "$runner"
        '';
      };
    };

  # Projects which provide an asv.conf.json file defining a benchmark suite
  # We handle these separately to normal builds since they should never run
  # concurrently with any other job, since that would interfere with timings.
  benchmarkRepos    = [ "bucketing-algorithms" ];
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
            flock -s "/tmp/benchmark-locks/$NODE" -c /home/chris/System/Tests/run
          '';
        };
      };
    };

  jobs = {
    jobs = fold mergeAttrs {}
      (attrValues (simpleNixRepos // benchmarkRepoJobs // laptopOverrides));
  };

  nodes = if machine == "laptop"
             then {
                    nodes = {
                      "laptop.conf" = writeScript "laptop.conf" ''
                        EXECUTORS=1
                      '';
                    };
                  }
             else {};

  combined = attrsToDirs (jobs // nodes);

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
