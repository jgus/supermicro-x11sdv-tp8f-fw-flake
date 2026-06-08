{
  description = "Devshell + bundled firmware for flashing Supermicro X11SDV-4C-TP8F (SYS-5019D-4C-FN8TP) BIOS/BMC in-band";

  # Standalone flashing toolbox (entered via `nix develop github:jgus/supermicro-x11sdv-tp8f-fw-flake`), self-contained
  # with its own nixpkgs pin; the proprietary firmware is fetched straight from Supermicro. Makes no assumptions about
  # the host it flashes — intended to run from a bare machine or a NixOS live installer.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        # SUM and the firmware blob are proprietary Supermicro binaries.
        pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };

        # Supermicro Update Manager — proprietary glibc ELF; in-band flasher for BOTH BIOS (UpdateBios) and BMC (UpdateBmc).
        # Direct, fetchable vendor URL (the click-through portal only gates the firmware bundle, not the SUM tarball).
        sum = pkgs.stdenv.mkDerivation {
          pname = "supermicro-sum";
          version = "2.15.0";
          src = pkgs.fetchurl {
            url = "https://www.supermicro.com/Bios/sw_download/1026/sum_2.15.0_Linux_x86_64_20251104.tar.gz";
            hash = "sha256-bRlGDrpeac/SN5eAfDgh44c5w9JiIKbEDcaiQ4k0g+I=";
          };
          nativeBuildInputs = [ pkgs.autoPatchelfHook ];
          buildInputs = [ pkgs.stdenv.cc.cc.lib pkgs.zlib ];
          dontConfigure = true;
          dontBuild = true;
          # Keep SUM's vendor layout intact (sum resolves ExternalData/ and the sum_bios driver source relative to its
          # own location) and expose it on PATH via a symlink — /proc/self/exe still resolves into the libexec dir.
          installPhase = ''
            runHook preInstall
            mkdir -p $out/libexec/supermicro-sum
            cp -r sum ExternalData driver ReleaseNote.txt SUM_UserGuide.pdf $out/libexec/supermicro-sum/ 2>/dev/null || true
            chmod +x $out/libexec/supermicro-sum/sum
            mkdir -p $out/bin
            ln -s $out/libexec/supermicro-sum/sum $out/bin/sum
            runHook postInstall
          '';
          meta = {
            description = "Supermicro Update Manager (in-band BIOS/BMC flasher)";
            license = pkgs.lib.licenses.unfree;
            platforms = [ "x86_64-linux" ];
            mainProgram = "sum";
          };
        };

        # Loads the IPMI KCS modules from the *running* kernel (the flake can't ship kernel modules — they're tied to the
        # booted kernel, not nixpkgs). `sudo` resolves modprobe from the host system, so this works on a NixOS installer.
        load-ipmi = pkgs.writeShellScriptBin "smc-load-ipmi" ''
          set -e
          echo "Loading IPMI modules from the running kernel: ipmi_si ipmi_devintf"
          sudo modprobe ipmi_si ipmi_devintf
          if [ -e /dev/ipmi0 ]; then
            echo "/dev/ipmi0 is present — in-band sum is ready."
          else
            echo "No /dev/ipmi0 after modprobe — board may lack IPMI/KCS, or the running kernel lacks the modules." >&2
            exit 1
          fi
        '';

        # Offline Supermicro product-key encoder (zsrv/supermicro-product-key, MIT). Generates the "non-JSON" key
        # format (gen 10/11/select-12) whose validator the BMC recomputes locally from the key's own fields — so a
        # SFT-DCMS-SINGLE key, which the bare OOB HMAC can't express, is mintable offline. X12+ "JSON" keys are
        # RSA-signed and NOT forgeable this way.
        product-key-tool = pkgs.buildGoModule {
          pname = "supermicro-product-key";
          version = "1.2.0";
          src = pkgs.fetchFromGitHub {
            owner = "zsrv";
            repo = "supermicro-product-key";
            rev = "v1.2.0";
            hash = "sha256-7+LJNaNxWoYfw8iG+mfbA6Cu0YYXDmNHV+6iMD6ny/Y=";
          };
          vendorHash = "sha256-Rf+PDGhGqi3FllOBZp8FLG9g6WnK35aEs49Ne9W3N5M=";
          meta = {
            description = "Generate/decode Supermicro BMC product keys offline";
            license = pkgs.lib.licenses.mit;
            mainProgram = "supermicro-product-key";
          };
        };

        # BMC license key generator.
        #   default / --sku SFT-OOB-LIC : HMAC-SHA1-96(secret, BMC-MAC) — the OOB node key (peterkleissner.com/2018/05/27),
        #                                 unlocking OOB BIOS flashing. SKU-agnostic, a pure function of the MAC.
        #   --sku SFT-DCMS-SINGLE (etc.): the richer non-JSON key (via product-key-tool), which is what gates the DCMS
        #                                 features — HTML5 iKVM virtual media, system lockdown — that OOB-LIC does not.
        license-keygen = pkgs.writeShellApplication {
          name = "smc-license-keygen";
          runtimeInputs = [ pkgs.ipmitool pkgs.python3 pkgs.gnused pkgs.coreutils product-key-tool ];
          text = ''
            sku="SFT-OOB-LIC"
            mac=""
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --sku) sku="$2"; shift 2 ;;
                --sku=*) sku="''${1#--sku=}"; shift ;;
                *) mac="$1"; shift ;;
              esac
            done
            if [ -z "$mac" ]; then
              # In-band, the dedicated BMC LAN is channel 1 on this board. Verify against the BMC web UI if unsure.
              mac=$(ipmitool lan print 1 2>/dev/null | sed -n 's/.*MAC Address *: *//p' | head -n1)
              if [ -z "$mac" ]; then
                echo "Could not read the BMC MAC (ipmitool lan print 1). Pass it: smc-license-keygen <MAC>" >&2
                exit 1
              fi
              echo "BMC MAC (LAN channel 1): $mac" >&2
            fi
            hex=$(printf '%s' "$mac" | tr 'A-F' 'a-f' | tr -cd '0-9a-f')
            if [ "''${#hex}" -ne 12 ]; then
              echo "MAC '$mac' is not 12 hex digits" >&2
              exit 1
            fi
            case "$sku" in
              SFT-OOB-LIC | OOB)
                python3 - "$hex" <<'PY'
            import hmac, hashlib, sys
            secret = bytes.fromhex("8544E3B47ECA58F9583043F8")
            k = hmac.new(secret, bytes.fromhex(sys.argv[1]), hashlib.sha1).hexdigest()[:24].upper()
            print("-".join(k[i:i + 4] for i in range(0, 24, 4)))
            PY
                ;;
              *)
                supermicro-product-key nonjson encode --sku "$sku" "$hex"
                ;;
            esac
          '';
        };

        # In-band node-key status / activation over /dev/ipmi0 (pass -i/-u/-p to instead target a BMC over the network).
        license-status = pkgs.writeShellApplication {
          name = "smc-license-status";
          runtimeInputs = [ sum ];
          text = ''
            echo "Querying BMC product-key status (in-band over /dev/ipmi0)..." >&2
            exec sum -c QueryProductKey "$@"
          '';
        };

        # No args: derive and activate BOTH the OOB and DCMS keys (the common case — full unlock with nothing to type).
        # A key passed explicitly activates just that one. Each activation is non-fatal so a re-run survives keys that
        # are already active.
        license-activate = pkgs.writeShellApplication {
          name = "smc-license-activate";
          runtimeInputs = [ sum license-keygen ];
          text = ''
            activate() {
              echo "Activating $1: $2" >&2
              if sum -c ActivateProductKey --key "$2"; then
                echo "  $1: ok" >&2
              else
                echo "  $1: non-zero (already active, or firmware rejected it)" >&2
              fi
            }
            if [ "$#" -gt 0 ]; then
              activate "key" "$1"
            else
              echo "No key given; deriving and activating OOB + DCMS keys from the BMC MAC..." >&2
              for sku in SFT-OOB-LIC SFT-DCMS-SINGLE; do
                activate "$sku" "$(smc-license-keygen --sku "$sku")"
              done
            fi
            echo "Done. Re-check with: smc-license-status" >&2
          '';
        };

        # X11SDV-TP8F software package (BIOS 2.2 / 2024-09-03, BMC 01.74.13 / 2023-08-02), fetched directly from
        # Supermicro's softfiles host (SoftwareItemID 23140 — bypasses the download-center disclaimer clickwrap).
        # The bundle nests per-component zips; extract them so the flashable images sit at predictable paths.
        firmware = pkgs.stdenv.mkDerivation {
          pname = "x11sdv-tp8f-firmware";
          version = "2.2_AS01.74.13";
          src = pkgs.fetchurl {
            url = "https://www.supermicro.com/Bios/softfiles/23140/X11SDV-TP8F_2.2_AS01.74.13_SUM2.14.0.zip";
            hash = "sha256-8/eh+VDIkEyXgxP7pi7lw8mSs/4x+LSMjahBzqYOnqg=";
          };
          nativeBuildInputs = [ pkgs.unzip ];
          dontConfigure = true;
          dontBuild = true;
          unpackPhase = "unzip -q $src -d outer";
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bios $out/bmc
            unzip -q "outer/BIOS_X11SDV-0986_20240903_2.2_STDsp.zip" -d $out/bios
            unzip -q "outer/BMC_X11AST2500-4101MS_20230802_01.74.13_STDsp.zip" -d $out/bmc
            cp outer/X11SDV-TP8F_Software_Package_Readme.txt $out/ 2>/dev/null || true
            runHook postInstall
          '';
          meta = {
            description = "Supermicro X11SDV-TP8F BIOS 2.2 + BMC 01.74.13 firmware bundle";
            license = pkgs.lib.licenses.unfree;
            platforms = [ "x86_64-linux" ];
          };
        };

        bios = "${firmware}/bios/BIOS_X11SDV-0986_20240903_2.2_STDsp.bin";
        bmc = "${firmware}/bmc/BMC_X11AST2500-4101MS_20230802_01.74.13_STDsp.bin";
      in
      {
        packages = { inherit sum firmware product-key-tool; default = sum; };

        devShells.default = pkgs.mkShellNoCC {
          buildInputs = [
            sum
            load-ipmi
            license-keygen
            license-status
            license-activate
            pkgs.ipmitool
            pkgs.pciutils
            pkgs.dmidecode
          ];
          shellHook = ''
            export SMC_FW="${firmware}"
            export SMC_BIOS="${bios}"
            export SMC_BMC="${bmc}"
            echo "--- Supermicro X11SDV-4C-TP8F (SYS-5019D-4C-FN8TP) firmware shell ---"
            echo "sum 2.15.0 | ipmitool | pciutils | dmidecode   BIOS 2.2 / BMC 01.74.13 in \$SMC_FW"
            echo "Confirm the board first:  sudo dmidecode -t baseboard"
            echo
            echo "In-band sum talks to the BMC over /dev/ipmi0 (IPMI KCS). On a fresh boot / live installer it isn't loaded yet:"
            if [ -e /dev/ipmi0 ]; then
              echo "  /dev/ipmi0: present"
            else
              echo "  /dev/ipmi0: MISSING -> run  smc-load-ipmi   (sudo modprobe ipmi_si ipmi_devintf, from the running kernel)"
            fi
            echo
            echo "Use tmux/screen, ensure stable power. Order: BMC first, then BIOS."
            echo "  BMC:   sudo sum -c UpdateBmc  --file \"\$SMC_BMC\""
            echo "  BIOS:  sudo sum -c UpdateBios --file \"\$SMC_BIOS\" --preserve_setting --reboot"
            echo
            echo "No-OS alternatives:  BMC -> web UI Maintenance/Firmware Update."
            echo "                     BIOS -> boot UEFI shell from USB, run flash.nsh (afuefi) from \$SMC_FW/bios."
            echo
            echo "BMC license:"
            echo "  smc-license-status                 # is a node key already activated?"
            echo "  smc-license-activate               # derive + activate BOTH OOB and DCMS keys (full unlock)"
            echo "  smc-license-keygen [--sku SFT-DCMS-SINGLE] [MAC]   # just print a key (OOB by default)"
          '';
        };
      });
}
