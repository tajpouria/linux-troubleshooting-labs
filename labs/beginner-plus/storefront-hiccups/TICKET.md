# INC-2453: Storefront freezes on and off, and some carts fail

    Severity     SEV-3 (customer-facing, intermittent)
    Status       Open, assigned to you (day-shift SRE)
    Service      Pinewood Books online storefront
    Host         web-03  (<LAB_IP>)
    Reported by  Customer Support
    Opened       09:40, Monday

## Summary

Since the weekend, customers say the storefront at http://<LAB_IP>/ "freezes":
a page hangs for a while, then everything is fast again. Separately, some
customers see "Sorry, we couldn't save your cart" when they add a book. Nobody
in the office can reproduce the cart problem. It works fine for us.

(`<LAB_IP>` is web-03's address on your computer's host-only network.
`vagrant up` prints it, and the copy of this ticket at /etc/lab/ticket.md has it
filled in.)

## What we know

- The uptime monitor checks http://<LAB_IP>/healthz once a minute. It has been
  green all week.
- Night on-call: "Looked at it twice, and both times it was fine. The access
  log is full of requests for /wp-login.php and /.env. Looks like a bot attack
  to me. Maybe we should block them?"
- The app team wanted to check the storefront's own log, but
  /var/log/storefront/app.log has been empty since the overnight housekeeping.
- Recent changes on web-03, from the change calendar:

      CHG-0496  3 weeks ago  Holiday readiness: housekeeping tweaks    (Platform)
      CHG-0507  2 weeks ago  Launch the "Trending now" shelf           (Sam, Platform)
      CHG-0519  yesterday    Storefront logging tidy-up                (App team)

## What we need from you

1. Stop the freezes and the cart errors.
2. Find the root causes. Expect more than one.
3. Don't throw customers' carts away, and don't switch features off. Marketing
   wants the Trending shelf, and its 5-minute refresh, to stay.
4. Make sure your fixes survive a reboot, and tonight's housekeeping.
5. Write a short post-incident note covering what went wrong, why, how you fixed
   it, and how to stop it from happening again.

## Access

- From the lab's folder on your computer (`labs/beginner-plus/storefront-hiccups`):
  `vagrant ssh` (you have sudo).
- Check your progress at any time: `sudo lab-check`
