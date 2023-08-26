{ config, lib, pkgs, ... }:

with lib;

{
  programs.git-cliff = {
    enable = true;

    settings = {
      header = "Changelog";
      footer = "<!-- generated by git-cliff -->";
      trim = true;
    };
  };

  test.stubs.git-cliff = { };

  nmt.script = ''
    assertFileContent \
      home-files/.config/git-cliff/cliff.toml \
      ${
        builtins.toFile "expected.toml" ''
          footer = "<!-- generated by git-cliff -->"
          header = "Changelog"
          trim = true
        ''
      }
  '';
}
