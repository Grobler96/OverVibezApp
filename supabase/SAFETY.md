# Safety runbook

How OverVibez finds and handles harmful or illegal content. This is an operating guide, not legal advice. Please have a solicitor or the
Online Safety Act guidance from Ofcom (ofcom.org.uk) confirm what applies to a service of your size.

## What the platform does automatically
* **Photos:** every new photo post is checked by an automatic moderation service (`scan-media`, every 30 seconds, needs the `OPENAI_API_KEY` secret).
  Anything over a cautious limit is **held**: hidden from everyone except staff, the creator is told it is being checked, and all staff are alerted.
  Anything that might involve a child is marked **urgent** and shown first.
* **Videos:** cannot be scanned automatically. They wait in Admin → Content → Review queue until a person has looked at them.
* **Reports:** every post, comment and message can be reported. Reports of **illegal content** or **under 18** alert all staff straight away and sit at the top of Admin → Reports.
* **Nothing is automatic and final.** A person always decides whether a held post goes back up or is removed. Removal can be appealed (Appeals tab, answered within 48 hours).
* If the scanner key is not set, uploads are not scanned and only the review queue and reports protect the platform. Admin → Overview shows a warning when that is the case.

## Daily routine (a few minutes)
1. Open Admin → Overview. Clear **Urgent reports** first, then **Posts held**, then the **Review queue**.
2. Held post: tap View, then **Keep it up** (only after looking) or **Remove** (a reason is required and the creator is notified).
3. Every decision is written to the audit log (Admin → Audit).

## If you find illegal content (especially anything involving a child)
1. **Do not** download, forward, screenshot or share it. Do not discuss the content with the uploader.
2. Remove the post (Admin → Content). Keep the removal record: the audit log keeps the post id, the account and the time.
3. Ban the account (Admin → Users) so it cannot post again.
4. **Report it**: child sexual abuse material to the Internet Watch Foundation (report.iwf.org.uk) and to the police or the National Crime Agency (999 if a child is in immediate danger);
   other illegal content to the police (101). Note the date, who you reported to and any reference number in the audit note.
5. Preserve evidence only as the police or IWF ask. Do not delete the account record while an investigation may be open.
6. Tell a solicitor if you are unsure what you must keep or disclose.

## Things still to do outside the code
* Join the **Internet Watch Foundation** (iwf.org.uk/membership) for image hash matching against known abuse imagery. This is the standard tool for UK platforms and needs an application and a fee, so it cannot be switched on from here.
* Write up a short **illegal content risk assessment** (what could go wrong on OverVibez and what you do about it). Ofcom publishes templates.
* Keep the **Terms, Guidelines and Privacy** pages current (they already mention automatic checks and moderator review).
