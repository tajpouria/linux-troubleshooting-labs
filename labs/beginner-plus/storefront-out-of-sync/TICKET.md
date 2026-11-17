# INC-2471: Stock levels, orders and delivery estimates out of sync with the warehouse

    Severity     SEV-2 (orders not reaching the warehouse)
    Status       Open, assigned to you (day-shift SRE)
    Service      Pinewood Books storefront and the Larch warehouse integration
    Host         web-05  (<LAB_IP>)
    Reported by  Customer Support, and Larch Logistics
    Opened       09:20, Wednesday

## Summary

A month ago Pinewood Books moved its warehouse to Larch Logistics. Larch's
agent, `larch`, runs on web-05 next to the storefront at http://<LAB_IP>/. It
fetches the warehouse's stock levels for the shop, sends our orders to the
warehouse, and gives the shop its delivery estimates. It's a closed-source
binary: we have no source code, and Larch support takes up to five working days
to answer.

Since yesterday, the shop and the warehouse disagree:

- Customers are buying books that the warehouse ran out of. The stock levels on
  the shop don't match the ones Larch shows us in their portal.
- Larch called: they haven't received a single order from us since early this
  morning. The shop keeps telling customers "Order placed".
- Book pages sometimes take several seconds to load, and sometimes they're
  instant. The home page is always fast. Every book page says "Usually ships in
  3-5 working days", even for books we have plenty of.

(`<LAB_IP>` is web-05's address on your computer's host-only network.
`vagrant up` prints it, and the copy of this ticket at /etc/lab/ticket.md has it
filled in.)

## What we know

- The uptime monitor checks http://<LAB_IP>/healthz once a minute. It has been
  green all along.
- Night on-call: "larch's log says `E2041 credential check failed` every two
  minutes. The key file is there, and its owner and permissions are exactly what
  Larch's README asks for. I checked. I also ran strace on larch, and the output
  is full of 'No such file or directory' errors, so I think the install is
  broken. Should we reinstall it?"
- Larch's support page: "To speed up your case, attach an strace of the
  failing command."
- Sam (Platform) is off today. Sam's handover note: "Larch asked about 3 of
  Monday's orders. Their warehouse shipped them, but we never got the
  acknowledgements. Larch is re-sending the acks on their side. Nothing for us
  to do."
- Recent changes on web-05, from the change calendar:

      CHG-0611  3 days ago  Upgrade larch 4.1 -> 4.2.1, tested against Larch's sandbox  (Sam, Platform)
      CHG-0618  yesterday   Rotate the Larch warehouse key                            (Security)

## What we need from you

1. Get stock levels, orders and book pages back to normal.
2. Find the root causes. Expect more than one.
3. Every order must reach the warehouse exactly once. Don't delete orders, and
   don't send any of them twice.
4. Keep the warehouse key secret, and keep the key Security issued. Don't run
   larch as root, and don't change Larch's binary.
5. Make sure your fixes survive a reboot.
6. Write a short post-incident note covering what went wrong, why, how you fixed
   it, and how to stop it from happening again.

## Access

- From the lab's folder on your computer (`labs/beginner-plus/storefront-out-of-sync`):
  `vagrant ssh` (you have sudo).
- Check your progress at any time: `sudo lab-check`
