# Welcome to Ankilatro (Balanki was already taken!)

## About:  
Are you in a class where the last thing you want to do is study? Can't bear getting past the authenticator app without doom scrolling reels for 3 hours? Welcome to ***Ankilatro***! A mod that tries to make you study by force feeding you Anki Cards between Balatro blinds! No longer will you have to force yourself to study. You must complete Anki Cards to be rewarded with that Sweet Sweet Dopamine of big number go up!

## Installation
### Required for basic reviews

- Balatro 1.0.1o or newer
- Lovely 0.8 or newer
- Steamodded 1.0.0~BETA-1016c or newer
- Anki desktop and a compatible [AnkiConnect](https://ankiweb.net/shared/info/2055492159) build that supports API version 6. The tested AnkiConnect build requires Anki 23.10 or newer.

Place the mod in your Balatro Mods folder. On Windows, this is `%APPDATA%\Balatro\Mods`.

### Optional features

| Feature | Additional requirements |
| --- | --- |
| **Anki scheduler** | Anki desktop 25.02 or newer and the bundled Ankilatro bridge |
| **Explain** | Anki desktop 25.02 or newer, the bundled Ankilatro bridge, [Ashton Long's Anki Explainer](https://github.com/AshtonLong/AnkiExplainer), and an OpenRouter API key configured in Anki Explainer |
| **Rephrased cloze cards** | Anki desktop 25.02 or newer, the bundled Ankilatro bridge, the Cloze Rephraser add-on, and an OpenRouter API key set in **Tools > Cloze Rephraser…** |

To install or update the bridge, open **Tools > Add-ons > View Files** in Anki. Copy the mod's `anki_addon/ankilatro_bridge` folder into Anki's `addons21` folder alongside AnkiConnect. Replace the previous copy if you already have the bridge, then restart Anki.

### Usage
Ensure that Anki is running and that AnkiConnect is installed; otherwise, the mod will be unable to retrieve cards.

At cash out, Ankilatro shows up to three cards by default. Open **Mods > Ankilatro > Config > Cards between rounds** to choose 0-50. The setting takes effect at the next cash out. Choose 0 to go straight to the shop.

**Card order** defaults to **Anki scheduler**. Choose **Random** to draw eligible cards at random, or **Oldest first** to draw eligible cards in Anki card creation order across decks. **Anki scheduler** uses the queue for the deck selected in Anki, including its configured order, learning steps, and daily limits. It requires the Ankilatro bridge described below.

The header shows **P** for pending reviews, **L** for learning or relearning cards, and **N** for new cards. Counts include the displayed card and refresh after each rating. **Anki scheduler** shows counts from Anki's current deck queue. **Random** and **Oldest first** count eligible cards across decks, exclude suspended and buried cards, and count new cards regardless of daily limits.

To stop seeing a card, choose **Suspend** to the right of the review panel, then **Confirm**. Ankilatro suspends it in Anki and shows another card; a suspended card doesn't count towards the blind's cards. Unsuspend it from Anki's browser.

If you rate a card by mistake, choose **Revert** at the bottom of that column. Ankilatro undoes the rating in Anki, as Anki's **Edit > Undo** would, and shows the card again with its answer revealed so you can rate it again. It counts towards the blind's cards again. Revert covers the last rating made on the current review screen, and it is also offered when that rating emptied the queue. It reads **Can't revert** when anything has changed in Anki since that rating, such as a review, an edit or a suspend; use **Edit > Undo** in Anki instead. Revert needs the Ankilatro bridge described below. You can't revert the blind's last card, because rating it continues to the shop.

Custom templates use the question and answer rendered by Anki, including the active deletion on numbered cloze cards. If a card has only images on one side, Ankilatro offers another draw. If the queue is empty or AnkiConnect reports an error, the review screen explains why and lets you retry or continue to the shop.

### Rephrased cloze cards

With the Cloze Rephraser add-on installed in Anki, cloze cards in Balatro use the same reworded sentences as Anki's own reviewer, so you recall the fact rather than recognise the wording. The hidden answers, cloze numbers and hints are unchanged, and the note itself is never edited. A card's first ever showing uses the original wording; later showings use a stored rewording. Rating a card in Balatro counts as seeing that wording, so the next showing picks a different one. Rewordings are generated in the background, so a card never waits on the model.

Cloze cards get a button to the right of the review panel, below **Suspend**. When the card is reworded, **Show original** switches to the note as written and **Show reworded** switches back. When the showing already uses the original wording, the button reads **Original** and is greyed out. Without the add-on, or with a bridge older than this version, cards show as written and there is no button. The add-on's own settings (on/off, number of stored rewordings, model) apply in Balatro too.

### Explain a card

Explain is optional. The **Explain** button only appears when Anki has both the Ankilatro bridge and Anki Explainer loaded; without them, reviews work as normal and the button is hidden. A bridge from before this check always shows the button, and Explain reports when Anki Explainer is missing. Ankilatro checks each time the review screen opens and when you choose **Retry**, so after installing either add-on, restart Anki and the button appears at the next cash out. If Anki wasn't running when the review screen opened, start it and choose **Retry**.

In Balatro, choose **Explain** to the right of the review panel. Before reveal, the popup uses Anki Explainer's question-side setting. After reveal, it explains the answer. Type a follow-up and press **Enter** or **Send**. Scroll the conversation with the mouse wheel or **Page Up** and **Page Down**.

The popup includes the add-on's follow-up actions, hints, quizzes, reasoning, retry, regenerate, copy, usage information, model selection, and conversation history. Use **Explain text** to paste or type an excerpt. **Settings** and **Account settings** open the installed add-on's dialogs in Anki. **Back to card** closes the popup. **Esc** first leaves the text field if it has focus.

Cards keep the formatting from Anki's editor, including headings, bold, italics, strikethrough, lists, and code, alongside MathJax. As in Anki, characters typed in a card, such as `*` and `_` in `my_rank*local_n*h`, show as typed rather than as Markdown. Explanations support common Markdown formatting, including quotes and link labels.

Explain uses the installed add-on's model and cache. On a cache miss, pressing Explain sends the card context to the configured model through OpenRouter. The API key stays in Anki.

## Current Limitations
- MathJax (`\(...\)` inline and `\[...\]` display) is rendered by a built-in LaTeX layout engine (`lib/akl_math.lua`). Common math (fractions, roots, scripts, sums/integrals, Greek, `\mathbb`, matrices, `cases`, `aligned`, `\left...\right`, accents) is supported; unsupported commands are shown in red as the raw `\command`.


## Future Updates
- [ ] SMODS Icon and other things
- [x] In Game Config
	- [ ] Deck Selection
	- [x] # Cards Between Blinds
	      
- [ ] Create own lovely text object with font that supports line wrapping and dynamic colouring
- [ ] Move review queue requests off the game thread
- [x] Mathjax



