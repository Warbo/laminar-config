with import <nixpkgs> {};
attrsToDirs {
  jobs = {
    "general-tests.run" = wrap {
      name   = "general-tests.run";
      paths  = [ bash nix ];
      vars   = withNix {};
      script = ''
        #!/usr/bin/env bash
        exec /home/chris/System/Tests/run
      '';
    };
  };
}
