# Play Store — this repo is not a Play app

This repository is the **Linux desktop bridge** (Omarchy bar widget + local
HTTP server). It is not uploaded to Google Play.

The two Play listings are the Wear OS **app** and the **watch face**. Both
Android packages are built and published from
[ai-omarchy-wearos](https://github.com/gladimdim/ai-omarchy-wearos):

| Play listing | Package | Status | Publish guide |
|---|---|---|---|
| Omarchy AI | `com.gladimdim.omarchy.ai.watch` | ⏳ In review — not yet on Play | [store/app/PUBLISH.md](https://github.com/gladimdim/ai-omarchy-wearos/blob/main/store/app/PUBLISH.md) |
| [Omarchy AI Watch Face](https://play.google.com/store/apps/details?id=com.gladimdim.omarchy.ai.watch.watchface) | `com.gladimdim.omarchy.ai.watch.watchface` | ✅ Live on Play | [store/watchface/PUBLISH.md](https://github.com/gladimdim/ai-omarchy-wearos/blob/main/store/watchface/PUBLISH.md) |

They are two Console apps on purpose. Watch Face Format cannot share an APK
with Kotlin, so they cannot share a listing.

What this repo *does* supply for Play:

---

## 1. Privacy policy (required on both listings)

Live URL:

https://gladimdim.github.io/omarchy-ai-companion/privacy.html

Source: [`docs/privacy.html`](../docs/privacy.html). GitHub Pages serves `/docs`
from `main`. **Push this repo and confirm the URL loads in a logged-out
browser before either listing is submitted.** A 404 privacy policy fails review.

---

## 2. Reviewer setup (App access)

Both Play listings declare restricted access: without this bridge on the same
Wi-Fi, the Wear OS app shows “No laptop found” and the face’s arcs stay empty.

The exact paste-blocks live in the wearos repo listing files. The instructions
send the reviewer here:

```
https://github.com/gladimdim/omarchy-ai-companion
python3 server.py
```

Keep `server.py` runnable with Python 3 and the standard library only. If that
stops being true, update both Play App access texts before the next review.

---

## 3. Play URLs on the marketing site

The site (`docs/index.html`) already links the **live watch-face** listing via
`WATCHFACE_URL`:

```
https://play.google.com/store/apps/details?id=com.gladimdim.omarchy.ai.watch.watchface
```

The Wear OS **app** QR stays parked on “in review” until that listing is live:

1. Open [`docs/index.html`](../docs/index.html) (around line 586).
2. Set `PLAY_URL` to the Omarchy AI **app** listing
   (`https://play.google.com/store/apps/details?id=com.gladimdim.omarchy.ai.watch`).
3. Push `main` so Pages picks it up.

Do not point `PLAY_URL` at the watch-face listing. The site is sending people
to the app that pairs with this bridge; the face has its own button + QR via
`WATCHFACE_URL`.

---

## Checklist for this repo around a Play submission

- [ ] `docs/privacy.html` is current and pushed; the URL above loads
- [ ] `python3 server.py` still runs with no extra deps (reviewer path)
- [ ] Watch face live link (`WATCHFACE_URL`) set and pushed
- [ ] After the Wear OS app is on Play: `PLAY_URL` filled in and pushed
