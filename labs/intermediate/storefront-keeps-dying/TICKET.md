# INC-2531: Storefront keeps dying, and search can't find the holiday books

    Severity     SEV-2 (customer-facing, repeated outages)
    Status       Open, assigned to you (day-shift SRE)
    Service      Pinewood Books online storefront
    Host         web-04  (<LAB_IP>)
    Reported by  Customer Support, Merchandising
    Opened       08:20, Thursday

## Summary

Since early this morning the storefront at http://<LAB_IP>/ drops out for a few
seconds, again and again: customers get "502 Bad Gateway", then it's back.
Every time, the storefront process has died and systemd has started it again.

Separately, Merchandising imported 28,000 holiday titles last week. They're on
the home page under "New arrivals", but search can't find any of them. Try
searching for "midwinter lanterns".

(`<LAB_IP>` is web-04's address on your computer's host-only network.
`vagrant up` prints it, and the copy of this ticket at /etc/lab/ticket.md has it
filled in.)

## What we know

- The uptime monitor checks http://<LAB_IP>/healthz once a minute. It has gone
  red for a single check a few times this morning, then green again.
- Night on-call: "Restarted the storefront twice. Each time it came back fine,
  and a few minutes later it died again. `top` shows search-server using about
  4 GB of memory on a server with 1.5 GB of RAM. That has to be the leak. Can we
  add a cron job that restarts search every hour?"
- web-04 has 2 vCPUs, 1.5 GB of RAM, and a 1 GB swap file as a safety net.
- The dashboards are empty this week: metrics-01 is offline for a rebuild
  (CHG-0601). Platform says it'll be back in a few days. Nothing to do on our
  side.
- Recent changes on web-04, from the change calendar:

      CHG-0577  3 weeks ago  Metrics agent hardening                      (Platform)
      CHG-0588  2 weeks ago  1 GB swap file as a safety net               (Kai, Platform)
      CHG-0596  last week    Import the holiday catalog (+28,000 titles)  (Merchandising)
      CHG-0601  5 days ago   Rebuild metrics-01 (offline for about a week) (Platform)

## What we need from you

1. Stop the storefront from dying.
2. Make the holiday titles searchable.
3. Find the root causes. Expect more than one.
4. Stay within Platform standard PS-12: the shop's services share one memory
   budget (`pinewood.slice`, 640 MB), and every batch job has a memory limit of
   its own, sized to what it needs. Don't raise the shop's budget and don't take
   anything out of it.
5. Keep the 10-minute catalog refresh (Merchandising needs it), the hourly search
   reindex, and the metrics agent (Monitoring wants this week's metrics when
   metrics-01 is back, but losing the oldest ones is acceptable). Services keep
   running as the users they run as today.
6. Make sure your fixes survive a reboot.
7. Write a short post-incident note covering what went wrong, why, how you fixed
   it, and how to stop it from happening again.

## Access

- From the lab's folder on your computer (`labs/intermediate/storefront-keeps-dying`):
  `vagrant ssh` (you have sudo).
- Check your progress at any time: `sudo lab-check`
