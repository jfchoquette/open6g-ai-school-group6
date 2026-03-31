# Usage
Push changes to this repository from your local machine.

Pull updates to the cloned repository at `/mnt/shared/open6g-ai-school-group6` within the persistent volume.

# Files
- `entrypoint_oai.sh` - Modified sample entrypoint script to start gNodeB. Added CLI arg handling to pass DL scheduler script path (first arg) and UL scheduler script path (second arg).
- `pf_dl_simple.lua` - Unmodified example DL scheduler script provided by NEU.
- `school_sierra_controller.py` - Unmodified UE controller script provided by NEU.
- `custom_dl.lua` - Copied from`pf_dl_simple.lua`, can be modified to test our own scheduling algorithm.
