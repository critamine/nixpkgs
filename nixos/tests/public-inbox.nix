{ pkgs, lib, ... }:
let
  orga = "example";
  domain = "${orga}.localdomain";

  tls-cert = pkgs.runCommand "selfSignedCert" { buildInputs = [ pkgs.openssl ]; } ''
    openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -nodes -days 36500 \
      -subj '/CN=machine.${domain}'
    install -D -t $out key.pem cert.pem
  '';

  gitRepositories = [
    "repo1"
    "repo2"
  ];
in
{
  name = "public-inbox";

  meta.maintainers = with pkgs.lib.maintainers; [ julm ];

  nodes.machine =
    {
      config,
      pkgs,
      nodes,
      ...
    }:
    let
      inherit (config.services) public-inbox;
    in
    {
      virtualisation.diskSize = 1 * 1024;
      virtualisation.memorySize = 1 * 1024;
      networking.domain = domain;

      security.pki.certificateFiles = [ "${tls-cert}/cert.pem" ];
      # If using security.acme:
      #security.acme.certs."${domain}".postRun = ''
      #  systemctl try-restart public-inbox-nntpd public-inbox-imapd
      #'';

      services.public-inbox = {
        enable = true;
        postfix.enable = true;
        openFirewall = true;
        settings.publicinbox = {
          css = [ "href=https://machine.${domain}/style/light.css" ];
          nntpserver = [ "nntps://machine.${domain}" ];
          wwwlisting = "match=domain";
        };
        mda = {
          enable = true;
          args = [ "--no-precheck" ]; # Allow Bcc:
        };
        http = {
          enable = true;
          port = "/run/public-inbox-http.sock";
          #port = 8080;
          args = [ "-W0" ];
          mounts = [
            "https://machine.${domain}/inbox"
          ];
        };
        nntp = {
          enable = true;
          #port = 563;
          args = [ "-W0" ];
          cert = "${tls-cert}/cert.pem";
          key = "${tls-cert}/key.pem";
        };
        imap = {
          enable = true;
          #port = 993;
          args = [ "-W0" ];
          cert = "${tls-cert}/cert.pem";
          key = "${tls-cert}/key.pem";
        };
        inboxes =
          lib.recursiveUpdate
            (lib.genAttrs gitRepositories (repo: {
              address = [
                # Routed to the "public-inbox:" transport in services.postfix.transport
                "${repo}@${domain}"
              ];
              description = ''
                ${repo}@${domain} :
                discussions about ${repo}.
              '';
              url = "https://machine.${domain}/inbox/${repo}";
              newsgroup = "inbox.comp.${orga}.${repo}";
              coderepo = [ repo ];
            }))
            {
              repo2 = {
                hide = [
                  "imap" # FIXME: doesn't work for IMAP as of public-inbox 1.6.1
                  "manifest"
                  "www"
                ];
              };
            };
        settings.coderepo = lib.listToAttrs (
          map (
            repositoryName:
            lib.nameValuePair repositoryName {
              dir = "/var/lib/public-inbox/repositories/${repositoryName}.git";
              cgitUrl = "https://git.${domain}/${repositoryName}.git";
            }
          ) gitRepositories
        );
      };

      # Use nginx as a reverse proxy for public-inbox-httpd
      services.nginx = {
        enable = true;
        recommendedGzipSettings = true;
        recommendedOptimisation = true;
        recommendedTlsSettings = true;
        recommendedProxySettings = true;
        virtualHosts."machine.${domain}" = {
          forceSSL = true;
          sslCertificate = "${tls-cert}/cert.pem";
          sslCertificateKey = "${tls-cert}/key.pem";
          locations."/".return = "302 /inbox";
          locations."= /inbox".return = "302 /inbox/";
          locations."/inbox".proxyPass = "http://unix:${public-inbox.http.port}:/inbox";
          # If using TCP instead of a Unix socket:
          #locations."/inbox".proxyPass = "http://127.0.0.1:${toString public-inbox.http.port}/inbox";
          # Referred to by settings.publicinbox.css
          # See http://public-inbox.org/meta/_/text/color/
          locations."= /style/light.css".alias = pkgs.writeText "light.css" ''
            * { background:#fff; color:#000 }

            a { color:#00f; text-decoration:none }
            a:visited { color:#808 }

            *.q { color:#008 }

            *.add { color:#060 }
            *.del {color:#900 }
            *.head { color:#000 }
            *.hunk { color:#960 }

            .hl.num { color:#f30 } /* number */
            .hl.esc { color:#f0f } /* escape character */
            .hl.str { color:#f30 } /* string */
            .hl.ppc { color:#c3c } /* preprocessor */
            .hl.pps { color:#f30 } /* preprocessor string */
            .hl.slc { color:#099 } /* single-line comment */
            .hl.com { color:#099 } /* multi-line comment */
            /* .hl.opt { color:#ccc } */ /* operator */
            /* .hl.ipl { color:#ccc } */ /* interpolation */

            /* keyword groups kw[a-z] */
            .hl.kwa { color:#f90 }
            .hl.kwb { color:#060 }
            .hl.kwc { color:#f90 }
            /* .hl.kwd { color:#ccc } */
          '';
        };
      };

      services.postfix = {
        enable = true;
        setSendmail = true;
        #sslCert = "${tls-cert}/cert.pem";
        #sslKey = "${tls-cert}/key.pem";
        recipientDelimiter = "+";
      };

      environment.systemPackages = [
        pkgs.gitMinimal
        pkgs.mailutils
        pkgs.openssl
      ];

    };

  testScript = ''
    start_all()

    # The threshold and/or hardening may have to be changed with new features/checks
    with subtest("systemd hardening thresholds"):
      print(machine.succeed("systemd-analyze security public-inbox-httpd.service --threshold=5 --no-pager"))
      print(machine.succeed("systemd-analyze security public-inbox-imapd.service --threshold=5 --no-pager"))
      print(machine.succeed("systemd-analyze security public-inbox-nntpd.service --threshold=4 --no-pager"))

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("public-inbox-init.service")

    machine.succeed(
      ${lib.concatMapStrings (repositoryName: ''
        "sudo -u public-inbox git init --bare -b main /var/lib/public-inbox/repositories/${repositoryName}.git",
      '') gitRepositories}
    )

    # List inboxes through public-inbox-httpd
    machine.wait_for_unit("public-inbox-httpd.socket")
    machine.wait_for_unit("nginx.service")
    machine.succeed("curl -L https://machine.${domain} | grep repo1@${domain}")
    # The repo2 inbox is hidden
    machine.fail("curl -L https://machine.${domain} | grep repo2@${domain}")

    # Send a mail and read it through public-inbox-httpd
    # Must work too when using a recipientDelimiter.
    machine.wait_for_unit("postfix.service")
    machine.succeed("mail -t <${pkgs.writeText "mail" ''
      Subject: Testing mail
      From: root@localhost
      To: repo1+extension@${domain}
      Message-ID: <repo1@root-1>
      Content-Type: text/plain; charset=utf-8
      Content-Disposition: inline

      This is a testing mail.
    ''}")
    machine.sleep(10)
    machine.succeed("curl -L 'https://machine.${domain}/inbox/repo1/repo1@root-1/T/#u' | grep 'This is a testing mail.'")

    # Read a mail through public-inbox-imapd
    machine.wait_for_unit("public-inbox-imapd.socket")
    machine.succeed("openssl s_client -ign_eof -crlf -connect machine.${domain}:993 <${pkgs.writeText "imap-commands" ''
      tag login anonymous@${domain} anonymous
      tag SELECT INBOX.comp.${orga}.repo1.0
      tag FETCH 1 (BODY[HEADER])
      tag LOGOUT
    ''} | grep '^Message-ID: <repo1@root-1>'")

    # TODO: Read a mail through public-inbox-nntpd
    #machine.wait_for_unit("public-inbox-nntpd.socket")

    # Delete a mail.
    # Note that the use of an extension not listed in the addresses
    # require to use --all
    machine.succeed("curl -L https://machine.${domain}/inbox/repo1/repo1@root-1/raw | sudo -u public-inbox public-inbox-learn rm --all")
    machine.fail("curl -L https://machine.${domain}/inbox/repo1/repo1@root-1/T/#u | grep 'This is a testing mail.'")

    # Compact the database
    machine.succeed("sudo -u public-inbox public-inbox-compact --all")
  '';
}
