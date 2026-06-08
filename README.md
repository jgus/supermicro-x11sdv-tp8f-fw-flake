# supermicro-x11sdv-tp8f-fw-flake

A self-contained devshell + **pinned firmware** for flashing the **Supermicro X11SDV-4C-TP8F** board (the SYS-5019D-4C-FN8TP) BIOS and BMC **in-band** from Linux.

```bash
nix develop github:jgus/supermicro-x11sdv-tp8f-fw-flake
```

Standalone (like `github:jgus/connectx3-flake`), with its own `nixpkgs` pin. The firmware is pinned by `fetchurl` straight from Supermicro at build time — no blob committed here, nothing to download by hand.

## What it provides

- **`sum`** — Supermicro Update Manager 2.15.0, autoPatchelf'd to run on NixOS. In-band flasher for **both** BIOS (`UpdateBios`) and BMC (`UpdateBmc`).
- **`smc-load-ipmi`** — `sudo modprobe ipmi_si ipmi_devintf` + a `/dev/ipmi0` check (see below).
- **`ipmitool`**, **`pciutils`**, **`dmidecode`**.
- **`packages.firmware`** — the X11SDV-TP8F bundle, unpacked so the images sit at predictable paths. The shell exports `$SMC_BIOS` / `$SMC_BMC` / `$SMC_FW`.

Makes no assumptions about the host — designed to run on a bare machine booted from a NixOS live installer (or any Linux with the IPMI modules available).

## Firmware versions

| Component | Version | Image |
|---|---|---|
| BIOS | 2.2 (2024-09-03) | `BIOS_X11SDV-0986_20240903_2.2_STDsp.bin` |
| BMC/IPMI | 01.74.13 (2023-08-02) | `BMC_X11AST2500-4101MS_20230802_01.74.13_STDsp.bin` |
| SUM | 2.15.0 (2025-11-04) | fetched from Supermicro |

Source bundle `X11SDV-TP8F_2.2_AS01.74.13_SUM2.14.0.zip` (SHA256 `f3f7a1f950c8904c978313fba62ee5c3c992b3fe31f8b48c8da841cea60e9ea8`), pinned by `fetchurl` from Supermicro's direct softfiles URL <https://www.supermicro.com/Bios/softfiles/23140/X11SDV-TP8F_2.2_AS01.74.13_SUM2.14.0.zip> (the [download-center page](https://www.supermicro.com/en/support/resources/downloadcenter/firmware/MBD-X11SDV-4C-TP8F/BIOS) is the human-facing equivalent; TP8F firmware is shared across the 4C/8C/12C/16C variants). The NICs (X552 10G, i350 1GbE, X557 PHY) carry firmware in the BIOS — no separate NIC flashing.

## Process (run on the target)

In-band `sum` talks to the BMC over `/dev/ipmi0` (the IPMI KCS interface). On a freshly-booted machine — including the NixOS live installer — the modules aren't loaded yet, and **the flake can't ship them**: kernel modules are tied to the running kernel, not to this flake's pinned nixpkgs. They come from the booted kernel instead (the standard NixOS installer kernel includes `ipmi_si`/`ipmi_devintf`):

```bash
nix develop github:jgus/supermicro-x11sdv-tp8f-fw-flake   # enable flakes on the installer if needed
smc-load-ipmi                                  # = sudo modprobe ipmi_si ipmi_devintf, then checks /dev/ipmi0
sudo dmidecode -t baseboard                    # sanity-check you're on an X11SDV-4C-TP8F
```

Then, with `tmux`/`screen` and stable power, update **BMC first, then BIOS**:

```bash
sudo sum -c UpdateBmc  --file "$SMC_BMC"
sudo sum -c UpdateBios --file "$SMC_BIOS" --preserve_setting --reboot
```

No-OS alternatives (need no Linux tooling at all):

- **BMC** — web UI → **Maintenance → Firmware Update** (just needs network to the BMC).
- **BIOS** — boot the **UEFI shell** from USB and run `flash.nsh` (`afuefi.smc`); the files are in `$SMC_FW/bios` (also `$SMC_FW/bmc/2.09/AuUpdate.efi` for the BMC).

## Licensing

In-band SUM `UpdateBios`/`UpdateBmc` and the web-UI BMC update are **free**. A per-node **SFT-DCMS-SINGLE** (or SFT-OOB-LIC) license is needed only for **OOB SUM** (over the BMC network), **BIOS update via the web UI**, and **HTML5 iKVM virtual media**. The firmware is Supermicro's proprietary property, fetched from Supermicro at build time (not redistributed by this repo).

### BMC license tools

The shell ships three helpers, all operating **in-band** over `/dev/ipmi0` (add `-i <bmc> -u <user> -p <pass>` to target a BMC over the network instead):

```bash
smc-license-status                              # QueryProductKey — is a node key already activated?
smc-license-activate                            # derive + activate BOTH the OOB and DCMS keys (full unlock)
smc-license-keygen [--sku SFT-DCMS-SINGLE] [MAC] # just print a key (OOB by default), e.g. to apply elsewhere
```

With no args, `smc-license-activate` derives both keys from the BMC's own MAC and activates each (tolerating any that are already active) — the one-command full unlock. Pass a key explicitly to activate just that one.

**There are two different keys, and they unlock different things:**

- **OOB key** — `HMAC-SHA1-96(secret, BMC-MAC)`, the classic 24-hex `XXXX-…` string ([reverse-engineered by Peter Kleissner](https://peterkleissner.com/2018/05/27/reverse-engineering-supermicro-ipmi/); the secret is constant across the X9–X11 generation). It is a pure function of the MAC and carries **no SKU**. It unlocks the **SFT-OOB-LIC** feature set — OOB BIOS flashing (OOB SUM + web-UI BIOS update). It does **not** unlock HTML5 iKVM virtual media. This is what `smc-license-keygen` produces by default.
- **DCMS key** — the longer "non-JSON" key (344-char base64). Its validator is recomputed by the BMC from the key's own fields, so on **gen 10/11** boards (this X11) it is mintable **offline** — no Supermicro signing key needed. A `--sku SFT-DCMS-SINGLE` key adds the DCMS features the OOB key lacks: **HTML5 iKVM / virtual media, system lockdown, etc.** Generated here via [`zsrv/supermicro-product-key`](https://github.com/zsrv/supermicro-product-key), exposed as `packages.product-key-tool`.

So to enable **HTML5 virtual media**, the OOB key is not enough — you need the DCMS key. The default `smc-license-activate` (no args) already applies both, so it covers this. To apply only the DCMS key:

```bash
smc-license-activate "$(smc-license-keygen --sku SFT-DCMS-SINGLE)"
```

> **Generation matters.** Gen 9 has only the OOB key (no non-JSON). Gen 10/11 (this board) support the offline-forgeable non-JSON DCMS key. **X12+** moved to RSA-**signed** "JSON" keys that are *not* forgeable this way — there, neither tool helps and you need a real license. The DCMS *suite software* (SSM/SPM central management) is a separate entitlement regardless.

**No-license fallback for virtual media:** the **Java**-based iKVM console can attach an ISO without any DCMS license (only the HTML5 console enforces it) — or mount the ISO via a CIFS/Samba share. Useful if a self-minted DCMS key is rejected by your firmware.
