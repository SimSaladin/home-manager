{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.neomutt;

  neomuttAccounts =
    filter (a: a.neomutt.enable) (attrValues config.accounts.email.accounts);

  sidebarModule = types.submodule {
    options = {
      enable = mkEnableOption "sidebar support";

      width = mkOption {
        type = types.int;
        default = 22;
        description = "Width of the sidebar";
      };

      shortPath = mkOption {
        type = types.bool;
        default = true;
        description = ''
          By default sidebar shows the full path of the mailbox, but
          with this enabled only the relative name is shown.
        '';
      };

      format = mkOption {
        type = types.str;
        default = "%D%?F? [%F]?%* %?N?%N/?%S";
        description = ''
          Sidebar format. Check neomutt documentation for details.
        '';
      };
    };
  };

  sortOptions = [
    "date"
    "date-received"
    "from"
    "mailbox-order"
    "score"
    "size"
    "spam"
    "subject"
    "threads"
    "to"
  ];

  bindModule = types.submodule {
    options = {
      map = mkOption {
        type = let
          menus = [
            "alias"
            "attach"
            "browser"
            "compose"
            "editor"
            "generic"
            "index"
            "mix"
            "pager"
            "pgp"
            "postpone"
            "query"
            "smime"
          ];
        in with types; either (enum menus) (listOf (enum menus));
        default = "index";
        description = "Select the menu to bind the command to.";
      };

      key = mkOption {
        type = types.str;
        example = "<left>";
        description = "The key to bind.";
      };

      action = mkOption {
        type = types.nullOr types.str;
        example = "<enter-command>toggle sidebar_visible<enter><refresh>";
        description = "Specify the action to take.";
      };

      description = mkOption {
        type = types.str;
        default = "";
        description = "Description of the macro.";
      };
    };
  };

  mkNotmuchVirtualboxes = virtualMailboxes:
    "${concatStringsSep "\n" (map ({ name, query, limit, type }:
      ''
        virtual-mailboxes "${name}" "notmuch://?query=${lib.escapeURL query}${
          optionalString (limit != null) "&limit=${toString limit}"
        }${optionalString (type != null) "&type=${type}"}"'')
      virtualMailboxes)}";

  setOption = n: v: if v == null then "unset ${n}" else "set ${n}=${v}";
  escape = replaceStrings [ "%" ] [ "%25" ];

  accountFilename = account: config.xdg.configHome + "/neomutt/" + account.name;

  genCommonFolderHooks = account:
    with account; {
      from = "'${address}'";
      realname = "'${realName}'";
      spoolfile = "'+${folders.inbox}'";
      record = if folders.sent == null then null else "'+${folders.sent}'";
      postponed = "'+${folders.drafts}'";
      trash = "'+${folders.trash}'";
    };

  mtaSection = account:
    with account;
    let passCmd = concatStringsSep " " passwordCommand;
    in if neomutt.sendMailCommand != null then {
      sendmail = "'${neomutt.sendMailCommand}'";
    } else
      let
        smtpProto =
          if smtp.tls.enable && !smtp.tls.useStartTls then "smtps" else "smtp";
        smtpPort = if smtp.port != null then ":${toString smtp.port}" else "";
        smtpBaseUrl =
          "${smtpProto}://${escape userName}@${smtp.host}${smtpPort}";
      in {
        smtp_url = "'${smtpBaseUrl}'";
        smtp_pass = ''"`${passCmd}`"'';
      };

  genMaildirAccountConfig = account:
    with account;
    let
      folderHook = mapAttrsToList setOption (genCommonFolderHooks account
        // optionalAttrs cfg.changeFolderWhenSourcingAccount {
          folder = "'${account.maildir.absPath}'";
        });
    in ''
      ${concatStringsSep "\n" folderHook}
    '';

  genImapAccountConfig = account:
    with account;
    let
      passCmd = concatStringsSep " " passwordCommand;
      folderHook = mapAttrsToList setOption (genCommonFolderHooks account // {
        folder = "'imaps://${escape userName}@${imap.host}:${toString imap.port}/'";
        imap_user = "'${userName}'";
        imap_pass = "\"`${passCmd}`\"";
      });
    in ''
      ${concatStringsSep "\n" folderHook}
    '';

  registerAccount = account:
    let
      mailboxes = if account.neomutt.mailboxName == null then
        "mailboxes"
      else
        ''named-mailboxes "${account.neomutt.mailboxName}"'';
      extraMailboxes = concatMapStringsSep "\n" (extra:
        if isString extra then
          ''mailboxes "${account.maildir.absPath}/${extra}"''
        else if extra.name == null then
          ''mailboxes "${account.maildir.absPath}/${extra.mailbox}"''
        else
          ''
            named-mailboxes "${extra.name}" "${account.maildir.absPath}/${extra.mailbox}"'')
        account.neomutt.extraMailboxes;
      folder = with account;
        if account.maildir != null then
          "${account.maildir.absPath}"
        else "imaps://${escape userName}@${imap.host}:${toString imap.port}";
    in with account; ''
      # register account ${name}
      source ${accountFilename account}
      mailboxes "${folder}/${folders.inbox}"

      set my_account_folder_${name} = '${folder}/'
      set my_account_hook_${name} = "set imap_user='$imap_user'; set imap_pass='$imap_pass'; set imap_authenticators='$imap_authenticators'; set imap_oauth_refresh_command='$imap_oauth_refresh_command'"
      set my_folder_hook_${name} = "set folder='$folder'; set spoolfile='$spoolfile'; set record='$record'; set postponed='$postponed'; set trash='$trash'; set copy='$copy'"
    '';

  accountHooks = account:
  with account;
  ''
    folder-hook ($my_account_folder_${name}) "$my_folder_hook_${name}"
    account-hook ($my_account_folder_${name}) "$my_account_hook_${name}"
  '';
  # XXX reset:
  #    account-hook . 'unset imap_user imap_pass imap_oauth_refresh_command; reset imap_authenticators'

  mraSection = account:
    with account;
    if account.maildir != null then
      genMaildirAccountConfig account
    else if account.imap != null then
      genImapAccountConfig account
    else
      throw "Only maildir and imap are supported at the moment";

  optionsStr = attrs: concatStringsSep "\n" (mapAttrsToList setOption attrs);

  sidebarSection = ''
    # Sidebar
    set sidebar_visible = yes
    set sidebar_short_path = ${lib.hm.booleans.yesNo cfg.sidebar.shortPath}
    set sidebar_width = ${toString cfg.sidebar.width}
    set sidebar_format = '${cfg.sidebar.format}'
  '';

  genBindMapper = bindType:
    concatMapStringsSep "\n" (bind:
      if bind.action == null then
        ''
          un${bindType} ${
            concatStringsSep "," (toList bind.map)
          } ${bind.key}''
      else
        ''
          ${bindType} ${
            concatStringsSep "," (toList bind.map)
          } ${bind.key} "${bind.action}"'');

  bindSection = (genBindMapper "bind") cfg.binds;

  macroSection = (genBindMapper "macro") cfg.macros;
# XXX TODO macro descriptions
# macroSection = concatMapStringsSep "\n"
#   (macro: ''macro ${macro.map} ${macro.key} "${macro.action}" "${macro.description}"'') cfg.macros;

  mailCheckSection = ''
    set mail_check_stats
    set mail_check_stats_interval = ${toString cfg.checkStatsInterval}
  '';

  notmuchSection = account:
    let virtualMailboxes = account.notmuch.neomutt.virtualMailboxes;
    in with account; ''
      # notmuch section
      set nm_default_uri = "notmuch://${config.accounts.email.maildirBasePath}"
      ${optionalString
      (notmuch.neomutt.enable && builtins.length virtualMailboxes > 0)
      (mkNotmuchVirtualboxes virtualMailboxes)}
    '';

  accountStr = account:
    with account;
    let
      signature = if account.signature.showSignature == "none" then
        "unset signature"
      else if account.signature.command != null then
        ''set signature = "${account.signature.command}|"''
      else
        "set signature = ${
          pkgs.writeText "signature.txt" account.signature.text
        }";
    in ''
      # Generated by Home Manager.
      set ssl_force_tls = ${
        lib.hm.booleans.yesNo (smtp.tls.enable || smtp.tls.useStartTls)
      }
      set certificate_file=${toString config.accounts.email.certificatesFile}

      # GPG section
      set crypt_autosign = ${lib.hm.booleans.yesNo (gpg.signByDefault or false)}
      set crypt_opportunistic_encrypt = ${
        lib.hm.booleans.yesNo (gpg.encryptByDefault or false)
      }
      set pgp_use_gpg_agent = yes
      set mbox_type = ${if maildir != null then "Maildir" else "mbox"}
      set sort = "${cfg.sort}"

      # MTA section
      ${optionsStr (mtaSection account)}

      ${optionalString (cfg.checkStatsInterval != null) mailCheckSection}

      ${optionalString cfg.sidebar.enable sidebarSection}

      # MRA section
      ${mraSection account}

      # Extra configuration
      ${account.neomutt.extraConfig}

      ${signature}
    ''
    + optionalString (account.notmuch.enable && account.notmuch.neomutt.enable)
    (notmuchSection account);

in {
  options = {
    programs.neomutt = {
      enable = mkEnableOption "the NeoMutt mail client";

      package = mkOption {
        type = types.package;
        default = pkgs.neomutt;
        defaultText = literalExpression "pkgs.neomutt";
        description = "The neomutt package to use.";
      };

      sidebar = mkOption {
        type = sidebarModule;
        default = { };
        description = "Options related to the sidebar.";
      };

      binds = mkOption {
        type = types.listOf bindModule;
        default = [ ];
        description = "List of keybindings.";
      };

      macros = mkOption {
        type = types.listOf bindModule;
        default = [ ];
        description = "List of macros.";
      };

      sort = mkOption {
        # allow users to choose any option from sortOptions, or any option prefixed with "reverse-"
        type = types.enum
          (sortOptions ++ (map (option: "reverse-" + option) sortOptions));
        default = "threads";
        description = "Sorting method on messages.";
      };

      vimKeys = mkOption {
        type = types.bool;
        default = false;
        description = "Enable vim-like bindings.";
      };

      checkStatsInterval = mkOption {
        type = types.nullOr types.int;
        default = null;
        example = 60;
        description = "Enable and set the interval of automatic mail check.";
      };

      editor = mkOption {
        type = types.str;
        default = "$EDITOR";
        description = "Select the editor used for writing mail.";
      };

      settings = mkOption {
        type = types.attrsOf (types.nullOr types.str);
        default = { };
        description = "Extra configuration appended to the end.";
      };

      changeFolderWhenSourcingAccount =
        mkEnableOption "changing the folder when sourcing an account" // {
          default = true;
        };

      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = "Extra configuration appended to the end.";
      };
    };

    accounts.email.accounts = mkOption {
      type = with types; attrsOf (submodule (import ./neomutt-accounts.nix));
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ cfg.package ];
    home.file = let
      rcFile = account: {
        "${accountFilename account}".text = accountStr account;
      };
    in foldl' (a: b: a // b) { } (map rcFile neomuttAccounts);

    xdg.configFile."neomutt/neomuttrc" = mkIf (neomuttAccounts != [ ]) {
      text = let
        # Find the primary account, if it has neomutt enabled;
        # otherwise use the first neomutt account as primary.
        primary =
          head (filter (a: a.primary) neomuttAccounts ++ neomuttAccounts);
      in ''
        # Generated by Home Manager.
        set header_cache = "${config.xdg.cacheHome}/neomutt/headers/"
        set message_cachedir = "${config.xdg.cacheHome}/neomutt/messages/"
        set editor = "${cfg.editor}"
        set implicit_autoview = yes
        set crypt_use_gpgme = yes

        alternative_order text/enriched text/plain text

        set delete = yes

        # Binds
        ${bindSection}

        # Macros
        ${macroSection}

        ${optionalString cfg.vimKeys
        "source ${pkgs.neomutt}/share/doc/neomutt/vim-keys/vim-keys.rc"}

        # Register accounts
        ${concatMapStringsSep "\n" registerAccount neomuttAccounts}

        # Source primary account
        source ${accountFilename primary}

        # Account hooks
        ${concatMapStringsSep "\n" accountHooks neomuttAccounts}

        # Extra configuration
        ${optionsStr cfg.settings}

        ${cfg.extraConfig}
      '';
    };

    assertions = [{
      assertion =
        ((filter (b: (length (toList b.map)) == 0) (cfg.binds ++ cfg.macros))
          == [ ]);
      message =
        "The 'programs.neomutt.(binds|macros).map' list must contain at least one element.";
    }];

    warnings =
      let hasOldBinds = binds: (filter (b: !(isList b.map)) binds) != [ ];
      in mkIf (hasOldBinds (cfg.binds ++ cfg.macros)) [
        "Specifying 'programs.neomutt.(binds|macros).map' as a string is deprecated, use a list of strings instead. See https://github.com/nix-community/home-manager/pull/1885."
      ];
  };
}
