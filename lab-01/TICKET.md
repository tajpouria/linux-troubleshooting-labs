# INC-2207: Storefront down for customers

    Severity     SEV-2 (customer-facing outage)
    Status       Open, assigned to you (day-shift SRE)
    Service      Pinewood Books online storefront
    Host         web-01  (<LAB_IP>)
    Reported by  Customer Support
    Opened       07:52

## Summary

Customers can't load the Pinewood Books storefront at http://<LAB_IP>/.
The browser spins for a while and then gives up.

(`<LAB_IP>` is web-01's address on your Mac's host-only network. `vagrant up`
prints it, and the copy of this ticket at /etc/lab/ticket.md has it filled in.)

## Timeline (server time)

    02:14  Monitoring: disk usage alert on web-01.
    02:40  Night on-call acked the alert. Their note: "cleaned up some old
           logs on web-01, going back to bed." The disk alert is still firing.
    06:55  Monitoring: storefront HTTP check failing (timeout).
    07:45  Support: several customer emails saying "your website won't load".
    07:52  Ticket opened and assigned to day shift.

## What we know

- Customers and the office network both get a timeout loading the storefront.
- The server is up and SSH works.
- A change window ran on web-01 last night (CHG-0311, "routine maintenance,
  several items"). The engineer who ran it is on PTO today.

## What we need from you

1. Get the storefront working again for customers.
2. Find the root cause. There may be more than one.
3. Don't weaken security to make it work. Use the fix you'd defend in a
   post-incident review.
4. Make sure the fix survives a reboot.
5. Write a short post-incident note covering what broke, why, how you fixed
   it, and how to stop it from happening again.

## Access

- From the lab-01 folder on your Mac: `vagrant ssh` (you have sudo).
- Check your progress at any time: `sudo lab-check`
