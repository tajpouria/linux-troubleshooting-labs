# Setting up a Windows PC for the labs

On Windows the labs run on **VirtualBox**, and the lab VMs are x86-64. You
install the following once:

| Component                            | What it does                                    | Install method                 |
| ------------------------------------ | ----------------------------------------------- | ------------------------------ |
| Microsoft Visual C++ Redistributable | a runtime library VirtualBox needs              | `winget`                       |
| VirtualBox 7.1 or 7.2                | the hypervisor that runs the VMs                | `winget` or virtualbox.org     |
| Vagrant 2.4.9 or newer               | builds and manages the VMs from a `Vagrantfile` | `winget` or HashiCorp download |
| Git                                  | gets you a copy of this repository             | `winget` or git-scm.com        |

Vagrant talks to VirtualBox on its own, so unlike on a Mac there's no plugin or
helper service to install.

**What you need:**

- Windows 10 or 11, 64-bit, on an Intel or AMD processor. (Windows on Arm isn't
  supported.)
- Hardware virtualization turned on (step 1).
- 8 GB of RAM or more. A lab VM uses 1.5–2 GB.
- About 6 GB of free disk space per lab you keep, plus about 1 GB for the base box.
- An administrator account for the installs.

The commands below are for **PowerShell** (Windows Terminal opens it by default).

---

## 1. Check that virtualization is on

Open **Task Manager → Performance → CPU** and look for
**Virtualization: Enabled**.

If it says *Disabled*, restart into your PC's firmware settings (UEFI/BIOS) and
turn on **Intel Virtualization Technology (VT-x)** or **AMD SVM Mode**. The name
and location vary by manufacturer: search the web for your PC model plus
"enable virtualization".

## 2. Decide what to do about Hyper-V

Some Windows features run Windows itself on top of Microsoft's hypervisor
(Hyper-V): **WSL 2**, **Docker Desktop**, **Windows Sandbox**, the **Hyper-V**
and **Virtual Machine Platform** features, and **Core isolation → Memory
integrity**. When any of them is active, VirtualBox has to run *on top of*
Hyper-V. That works with VirtualBox 7, but VMs are slower and take longer to
boot. With the console open (`LAB_GUI=1`), you'll see a green turtle icon in
the VM window's status bar.

Check whether a hypervisor is running:

```powershell
(Get-CimInstance Win32_ComputerSystem).HypervisorPresent    # True = Hyper-V is active
```

You have two options:

- **Keep it on.** The labs still work, just slower. The performance lab
  (slow-storefront) measures how fast *your* VM is when healthy, so its checks
  stay fair.
- **Turn it off while you do the labs**, for full speed. In PowerShell **run as
  administrator**:

  ```powershell
  bcdedit /set hypervisorlaunchtype off     # then restart Windows
  ```

  While it's off, WSL 2, Docker Desktop, Windows Sandbox and other features
  that need the hypervisor don't work. To turn it back on, run
  `bcdedit /set hypervisorlaunchtype auto` (as administrator) and restart.

## 3. Install VirtualBox, Vagrant and Git

The quickest way is `winget`, which is built into Windows 10 and 11:

```powershell
winget install --id Microsoft.VCRedist.2015+.x64 -e
winget install --id Oracle.VirtualBox -e
winget install --id Hashicorp.Vagrant -e
winget install --id Git.Git -e
```

Accept the prompts. VirtualBox installs network drivers, so Windows may ask
for permission, and your network can drop for a few seconds. **Restart
Windows** afterwards, because Vagrant's installer asks for it.

No `winget`? Download the installers instead:
[VirtualBox](https://www.virtualbox.org/wiki/Downloads) ("Windows hosts"),
[Vagrant](https://developer.hashicorp.com/vagrant/install) (AMD64), and
[Git](https://git-scm.com/download/win). VirtualBox's installer tells you if
the Visual C++ Redistributable is missing.

Check the versions in a **new** PowerShell window:

```powershell
vagrant --version                                                  # 2.4.9 or newer
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" --version   # 7.1.x or 7.2.x
```

Each Vagrant release supports the VirtualBox versions that existed when it
came out: VirtualBox 7.1 needs Vagrant 2.4.2 or newer, and 7.2 needs 2.4.9 or
newer. If a newer VirtualBox comes out before Vagrant supports it, stay on the
newest version that Vagrant lists as supported.

## 4. Get the labs

```powershell
cd $HOME
git clone https://github.com/tajpouria/linux-troubleshooting-labs.git
cd linux-troubleshooting-labs
```

The repository keeps its scripts with Linux (LF) line endings, even on Windows.
If you edit a lab file, keep it that way. VS Code shows `LF` or `CRLF` in its
status bar.

## 5. Optional: pre-download the base box

`vagrant up` downloads the box automatically, but you can fetch it ahead of time
(about 1 GB):

```powershell
vagrant box add bento/ubuntu-24.04 --provider virtualbox --architecture amd64
vagrant box list         # expect: bento/ubuntu-24.04 (virtualbox, <version>, (amd64))
```

## 6. Smoke test

```powershell
cd labs\beginner\storefront-down
vagrant up
vagrant ssh -c "uname -m"    # expect: x86_64
```

The first `vagrant up` may ask for permission to change network settings while
it sets up VirtualBox's host-only network (`192.168.56.0/24`). Allow it. The lab
VMs live on that network: storefront-down is `192.168.56.11`, for example.

When you're done testing, either carry on with the lab (take the snapshot from
its README) or remove it with `vagrant destroy -f`.

---

## Using the labs from PowerShell

The lab instructions work as written, with a few PowerShell differences:

- **`curl`**: in Windows PowerShell, `curl` is a different command
  (`Invoke-WebRequest`). Type `curl.exe` for the real curl, which comes with
  Windows: `curl.exe -v --max-time 5 http://192.168.56.11/`. Inside the VM, `curl`
  is fine.
- **Quoting**: use double quotes for commands you pass into the VM:
  `vagrant ssh -c "sudo lab-check"`.
- **One command per line**: Windows PowerShell 5.1 doesn't understand `&&`. Run
  commands one after another, or separate them with `;`.
- **Environment variables**: `$env:LAB_GUI = "1"` sets one for the current
  window, and `Remove-Item Env:LAB_GUI` removes it.

## Troubleshooting the toolchain

| Symptom | Fix |
| --- | --- |
| `VT-x is disabled in the BIOS for all CPU modes (VERR_VMX_MSR_ALL_VMX_DISABLED)` or `AMD-V is disabled in the BIOS (VERR_SVM_DISABLED)` | Turn on virtualization in your firmware settings (step 1). |
| `vagrant up` hangs at "Waiting for machine to boot", times out, or the VM is very slow | Usually Hyper-V (step 2). Run `$env:LAB_GUI = "1"; vagrant reload` to watch the console. If you see a turtle icon, VirtualBox is running on top of Hyper-V. |
| `Vagrant has detected that you have a version of VirtualBox installed that is not supported by this version of Vagrant` | Update Vagrant (step 3), or install a VirtualBox version your Vagrant supports. |
| `The box 'bento/ubuntu-24.04' could not be found`, or no matching provider or architecture | Make sure `vagrant --version` is 2.4 or newer and you're online. Try step 5 explicitly. |
| `This lab runs on VirtualBox on this computer, but Vagrant picked '...'` | Run `vagrant up --provider virtualbox`. If you've set `VAGRANT_DEFAULT_PROVIDER` (for example to `hyperv`), remove it. |
| `VBoxManage.exe: error: Failed to create the host-only adapter`, or `The specified host network collides with a non-hostonly network!` | The host-only network couldn't be set up. Run the VirtualBox installer again, choose **Repair**, and restart Windows. A collision means something else (often a VPN) already uses `192.168.56.x`: disconnect it and try again. As a last resort, use the port-forward fallback below. |
| The lab's address doesn't load in your browser *before* you've started fixing things | That's expected. The lab is broken on purpose. To test the network path itself, `ping 192.168.56.11` (use your lab's address). If ping fails too, check for a VPN, then try the port-forward fallback. |
| Errors that mention paths under your user profile, especially if your Windows user name has spaces or non-English letters | Point Vagrant at a simple folder: `[Environment]::SetEnvironmentVariable("VAGRANT_HOME", "C:\vagrant-home", "User")`, open a new PowerShell window, and run `vagrant up` again. Boxes download again into the new folder. |
| Provisioning fails with `$'\r': command not found` | A script got Windows (CRLF) line endings. Clone the repo again, and keep LF endings when editing. |
| You locked yourself out of SSH (for example with a firewall rule) | Run `$env:LAB_GUI = "1"; vagrant reload` and log in on the console as `vagrant` / `vagrant`. Or restore your snapshot. |

**Port-forward fallback.** If the host-only network won't work, reach the lab
through `localhost` instead:

```powershell
$env:LAB_PORT_FORWARD = "1"; vagrant reload
# then open http://localhost:8011/ (8000 + the lab's host octet: 8011 for storefront-down)
```

Requests then reach the VM through VirtualBox's NAT, and the lab's checks still
count them as coming from outside the server.

## Uninstalling everything

```powershell
vagrant global-status --prune                    # find any lab VMs still around
# in each lab folder:  vagrant destroy -f
vagrant box remove bento/ubuntu-24.04 --all
winget uninstall --id Hashicorp.Vagrant -e
winget uninstall --id Oracle.VirtualBox -e
Remove-Item -Recurse -Force "$HOME\.vagrant.d"   # Vagrant's boxes and settings
```

If you turned the hypervisor off in step 2, turn it back on with
`bcdedit /set hypervisorlaunchtype auto` (as administrator) and restart.
