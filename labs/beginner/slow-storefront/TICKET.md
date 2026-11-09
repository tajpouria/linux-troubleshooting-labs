# INC-2318: Storefront painfully slow

    Severity     SEV-3 (customer-facing slowness)
    Status       Open, assigned to you (day-shift SRE)
    Service      Pinewood Books online storefront
    Host         web-02  (<LAB_IP>)
    Reported by  Customer Support
    Opened       08:05, Thursday

## Summary

The storefront at http://<LAB_IP>/ is up, but pages take many seconds to load.
Customers are giving up halfway through checkout. The uptime monitor only
checks http://<LAB_IP>/healthz and only alerts when that fails outright, so
it's still green.

(`<LAB_IP>` is web-02's address on your computer's host-only network.
`vagrant up` prints it, and the copy of this ticket at /etc/lab/ticket.md has it
filled in.)

## Timeline (server time)

    01:00  Nightly catalog reindex started.
    01:20  Monitoring: CPU at 100% on web-02. Also a warning: "free memory
           below 10%".
    01:35  Night on-call: "the storefront process was using a lot of CPU, so I
           put a temporary limit on it to keep the box responsive. Will look
           properly in the morning." The CPU alert is still firing.
    07:40  Support: several customers say the shop is "unusably slow".
    08:05  Ticket opened and assigned to day shift.

## What we know

- Every page loads eventually, but it can take 5 to 15 seconds. Normally a page
  takes a few tens of milliseconds.
- web-02 has 2 vCPUs and 1.5 GB of RAM.
- Last night's catalog export was about twice its usual size, because the
  holiday range was imported this week. Merchandising **needs the reindex to
  finish today** for the weekend sale. Don't cancel it.
- CHG-0420, "capacity testing for the holiday sale", was scheduled on web-02
  for Tuesday and Wednesday (owner: Dani, Platform team). Dani is on a
  long-haul flight today and can't be reached.

## What we need from you

1. Make the storefront fast again.
2. Find the root cause. There may be more than one.
3. Don't trade one problem for another. The reindex has to finish, and every
   service keeps running as the user it runs as today.
4. Make sure the fix survives a reboot, and tonight's 01:00 reindex.
5. Write a short post-incident note covering what was slow, why, how you fixed
   it, and how to stop it from happening again.

## Access

- From the lab's folder on your computer (`labs/beginner/slow-storefront`):
  `vagrant ssh` (you have sudo).
- Check your progress at any time: `sudo lab-check`
