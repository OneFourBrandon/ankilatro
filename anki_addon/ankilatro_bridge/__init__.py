"""Run Anki Explainer's controller for the card displayed in Balatro."""

import inspect
import sys
from types import SimpleNamespace
from uuid import uuid4

from aqt import gui_hooks

_session = None
_ACTIONS = {
    "explain", "ask", "chip", "stop", "copy", "regenerate", "retry",
    "stronger_hint", "show_answer_explain", "history", "history_open",
    "history_back", "history_close", "continue", "open_browser",
    "edit_card", "confirm_send", "confirm_cancel",
}


class GamePanel:
    """Translate the controller's panel updates into polled state."""

    def __init__(self):
        self.notice = None
        self.phase = None

    def set_state(self, state):
        self.notice = state.get("notice")
        if not (state.get("thread") or {}).get("busy"):
            self.phase = None

    def set_phase(self, thread_id, phase, info):
        self.phase = phase

    def is_visible(self):
        return True

    def has_focus(self):
        return False

    def show(self):
        pass

    def focus_input(self):
        pass

    # The controller stores deltas and terminal results in the thread itself.
    def append_delta(self, *args):
        pass

    def finish(self, *args):
        pass

    def error(self, *args):
        pass


def _clear():
    global _session
    if _session is not None:
        # The installed add-on owns the shared cache, so leave it open.
        _session["controller"].on_reviewer_end()
    _session = None


def _snapshot(session, revision=None):
    controller, panel = session["controller"], session["panel"]
    state = controller.view_state(panel.notice)
    if state["settings"]["reasoningDisplay"] != "collapsible" and state.get("thread"):
        for turn in state["thread"]["turns"]:
            turn.pop("reasoning", None)
    state["phase"] = panel.phase
    state["models"] = session["models"]
    state["revealed"] = session["host"].side == "answer"
    state["questionDisabled"] = controller.settings.question_side == "disabled"
    if state != session.get("state"):
        session["revision"] += 1
        session["state"] = state
    reply = {"token": session["token"], "revision": session["revision"]}
    if revision != session["revision"]:
        reply["state"] = state
    return reply


def ankilatroPanelOpen(self, cardId, side):
    global _session
    if "anki_explainer" not in sys.modules:
        raise RuntimeError("Install and enable Ashton Long's Anki Explainer in Anki.")
    if side not in ("question", "answer"):
        raise ValueError("Unknown card side.")

    from anki_explainer.explainer import hooks
    from anki_explainer.explainer.context.extractor import gather_raw
    from anki_explainer.explainer.controller import Controller
    from anki_explainer.explainer.llm.models import all_models
    from anki_explainer.explainer.ui.anki_host import AnkiHost

    class BalatroHost(AnkiHost):
        def __init__(self, svc, card, side):
            super().__init__(svc.settings, svc.open_settings)
            self.card_id = card.id
            self.side = side

        def current_card(self):
            return self.get_card(self.card_id)

        def reviewer_side(self):
            return self.side

        def gather_raw(self, card, side):
            return gather_raw(card, side, reviewer=None)

        def flip_card(self):
            self.side = "answer"
            controller.on_card_shown(self.current_card(), self.side)
            return True

        def focus_reviewer(self):
            pass

        def update_bar(self, state):
            pass

        def tooltip(self, message):
            panel.notice = message

        def edit_card(self, card_id):
            self.open_browser(card_id)

    card = self.getCard(cardId)
    svc = hooks.services()
    _clear()
    host = BalatroHost(svc, card, side)
    host.get_card = self.getCard
    panel = GamePanel()
    controller = Controller(host, svc.settings, svc.secrets, svc.cache)
    controller.attach_panel(panel)
    _session = {
        "token": uuid4().hex, "revision": 0, "controller": controller,
        "host": host, "panel": panel,
        "models": [{"id": model.id, "label": model.display_name} for model in all_models()],
    }
    controller.on_card_shown(card, side)
    controller.explain_pressed(source="panel")
    return _snapshot(_session)


def ankilatroPanelPoll(self, token, revision):
    if _session is None or token != _session["token"]:
        raise RuntimeError("This Anki Explainer session expired. Reopen Explain.")
    return _snapshot(_session, revision)


def ankilatroPanelAction(self, token, action, value=""):
    if _session is None or token != _session["token"]:
        raise RuntimeError("This Anki Explainer session expired. Reopen Explain.")
    controller, panel = _session["controller"], _session["panel"]
    panel.notice = None
    if action == "settings" or action == "account":
        controller.host.open_settings("account" if action == "account" else None)
    elif action == "model":
        if not any(model["id"] == value for model in _session["models"]):
            raise ValueError("Unknown model.")
        controller.settings.set("model", value)
        controller.settings.save()
        controller.on_settings_changed()
    elif action == "selection":
        if controller.active is None and value.strip():
            controller.explain_selection(value.strip()[:4000])
    elif action == "error_link":
        thread = (_snapshot(_session)["state"].get("thread") or {})
        for turn in reversed(thread.get("turns", [])):
            url = (turn.get("meta") or {}).get("error", {}).get("url")
            if url and url.startswith("https://openrouter.ai/"):
                controller.host.open_link(url)
                break
    elif action in _ACTIONS:
        if action in {"ask", "chip", "regenerate", "retry", "stronger_hint", "show_answer_explain", "explain"}:
            if controller.active is not None or controller.view == "confirm":
                return _snapshot(_session)
            if action == "ask" and controller.host.side == "question" and controller.settings.question_side == "disabled":
                panel.notice = "Question-side help is turned off in Anki Explainer settings."
                return _snapshot(_session)
        controller.handle_message({"op": action, "id": value, "text": value[:8000]})
    else:
        raise ValueError("Unknown Anki Explainer action.")
    return _snapshot(_session)


def ankilatroPanelClose(self, token):
    if _session is not None and token == _session["token"]:
        _clear()
    return True


def ankilatroExplainerAvailable(self):
    # Ankilatro only shows its Explain button when Anki Explainer is loaded.
    return "anki_explainer" in sys.modules


def _rephraser():
    """The Cloze Rephraser add-on's live instance, or None if it isn't loaded.

    Found by shape rather than folder name, so it works whether the add-on was
    installed from a file (``cloze_rephraser``) or from AnkiWeb (a numeric id).
    """
    for name, module in list(sys.modules.items()):
        if not name.endswith(".addon") or not hasattr(module, "Rephraser"):
            continue
        instance = getattr(module, "_rephraser", None)
        if instance is not None:
            return instance
    return None


def _queue_rewrite(r, card):
    """Have the rephraser generate a new alternate for this card's note in the
    background, unless it already has an unseen one or is at its cap.

    Best effort: a failure here must never stop Balatro showing the card."""
    try:
        chat = r._chat_fn()
        if chat is None or r.engine is None:
            return
        if len(inspect.signature(r._ensure_rewrite).parameters) >= 3:
            r._ensure_rewrite(card.nid, card.ord, chat)
        else:  # releases before 2026-11-25 took the queue entry
            r._ensure_rewrite(SimpleNamespace(note_id=card.nid, template_idx=card.ord), chat)
    except Exception:
        pass


def ankilatroRephrase(self, cardId):
    """Cloze Rephraser's wording for this card, as Balatro should show it.

    Returns None when the add-on isn't installed, so Ankilatro shows the note
    as stored. Otherwise returns ``{"rephrased": False}`` for cards the add-on
    leaves alone (not a cloze card, or the add-on is turned off), adds
    ``"cloze": True`` when it's a cloze card whose showing uses the original
    wording (first ever review, or no alternate generated yet), or returns
    the rewritten cloze fields by field name plus
    Anki's render of both sides from them. The note itself is never changed.
    """
    r = _rephraser()
    if r is None:
        return None
    if not r.enabled or r.cache is None:
        return {"rephrased": False}
    card = self.collection().get_card(cardId)
    note = card.note()
    if not r._is_cloze_card(card, note):
        return {"rephrased": False}
    # What this showing displays, fixed until the card is answered.
    pin = r._pin_for(card, note)
    # Queue a rewrite for this note's next showing, and for upcoming cards.
    _queue_rewrite(r, card)
    r.prefetch()
    rewritten = {ord_: text for ord_, (_hash, text, _new) in pin.fields.items()}
    # "cloze": the add-on handles this card, but this showing uses the original
    if not rewritten:
        return {"rephrased": False, "cloze": True}
    try:
        output = r._render(card, note, rewritten)
    except Exception:
        # Same rule as in Anki's reviewer: anything wrong shows the original.
        return {"rephrased": False, "cloze": True}
    names = [field["name"] for field in note.note_type()["flds"]]
    # Same shape as AnkiConnect's cardsInfo question/answer (card.question()).
    return {
        "rephrased": True,
        "fields": {names[ord_]: text for ord_, text in rewritten.items() if ord_ < len(names)},
        "question": output.question_and_style(),
        "answer": output.answer_and_style(),
    }


def ankilatroRephraseAnswered(self, cardId):
    """Record that Balatro's review of this card is done.

    Marks the wording it showed as seen, so the next showing gets a different
    one, and starts generating alternates for upcoming cards.
    """
    r = _rephraser()
    if r is None:
        return False
    card = self.collection().get_card(cardId)
    r.on_answer(None, card, 0)
    # The wording just shown is now used up, so ask for this card's next one
    # here: prefetch only covers Anki's current deck queue, which Random and
    # Oldest first don't follow.
    if r.enabled and r.cache is not None:
        _queue_rewrite(r, card)
    r.prefetch()
    return True


def ankilatroAnswer(self, cardId, ease):
    """Rate a card like AnkiConnect's answerCards, and return the undo step the
    rating made so Balatro can revert exactly that rating later."""
    if ease not in (1, 2, 3, 4):
        raise ValueError("Unknown rating.")
    card = self.getCard(cardId)
    card.start_timer()
    self.scheduler().answerCard(card, ease)
    _refresh_undo_menu()
    return {"undoStep": self.collection().undo_status().last_step}


def ankilatroUndoAnswer(self, undoStep):
    """Undo the rating Balatro made, as Edit > Undo in Anki would.

    Refuses when anything else has been undoable-changed in Anki since (another
    review, an edit, a suspend), so it never undoes something else."""
    col = self.collection()
    status = col.undo_status()
    if not status.undo or status.last_step != undoStep:
        raise RuntimeError("Anki has changed since that rating, so it can't be reverted here. Use Edit > Undo in Anki.")
    out = col.undo()
    try:
        # Let Anki's own screens refresh, as after its Edit > Undo.
        gui_hooks.operation_did_execute(out.changes, None)
        gui_hooks.state_did_undo(out)
    except Exception:
        pass
    _refresh_undo_menu()
    return True


def _refresh_undo_menu():
    try:
        from aqt import mw
        mw.update_undo_actions()
    except Exception:
        pass


def ankilatroNextScheduledCard(self):
    # Read the same current-deck queue as Anki's reviewer.
    queue = self.scheduler().get_queued_cards()
    return {
        "cardId": queue.cards[0].card.id if queue.cards else None,
        "pending": queue.review_count,
        "learning": queue.learning_count,
        "new": queue.new_count,
    }


def _register():
    connect = sys.modules.get("2055492159") or sys.modules.get("AnkiConnectDev")
    if connect is not None and hasattr(connect, "AnkiConnect"):
        for action in (
            ankilatroPanelOpen, ankilatroPanelPoll, ankilatroPanelAction,
            ankilatroPanelClose, ankilatroNextScheduledCard, ankilatroExplainerAvailable,
            ankilatroRephrase, ankilatroRephraseAnswered, ankilatroAnswer, ankilatroUndoAnswer,
        ):
            setattr(connect.AnkiConnect, action.__name__, connect.util.api()(action))


gui_hooks.profile_did_open.append(_register)
gui_hooks.profile_will_close.append(_clear)
