import AppKit
import Carbon
import FileKit

/// Maps key presses in the panel to browser actions. Text fields (search, rename) keep
/// their keys; everything else is handled here so it works without a menu bar.
@MainActor
final class KeyRouter {
    let model: AppModel
    weak var panel: NSPanel?
    weak var preview: PanelController?

    init(model: AppModel) { self.model = model }

    private var isEditingText: Bool {
        guard let responder = panel?.firstResponder as? NSTextView else { return false }
        return responder.isFieldEditor || responder.isEditable
    }

    /// Returns true if the event was consumed.
    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command), shift = flags.contains(.shift), option = flags.contains(.option)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = Int(event.keyCode)
        let pane = model.activePane

        // Sheets keep every key except Esc, which closes them.
        if model.sheet != nil {
            if code == kVK_Escape {
                if model.sheet == .rules { model.rules.saveNow() }
                model.sheet = nil
                return true
            }
            return false
        }
        // The compact strip is click-only: Esc hides it, Cmd-Z/Shift-Cmd-Z still undo sends.
        if model.isCompact {
            switch (code, cmd, key, shift) {
            case (kVK_Escape, _, _, _): preview?.hide(); return true
            case (_, true, "z", false): model.undo(); return true
            case (_, true, "z", true): model.redo(); return true
            default: return false
            }
        }

        // Shortcuts that also apply while typing in the search field.
        if cmd {
            switch key {
            case "f": model.focusSearchRequest += 1; return true
            case "w": preview?.hide(); return true
            default: break
            }
        }
        if isEditingText { return false }

        if cmd {
            switch (key, shift) {
            case ("z", false): model.undo(); return true
            case ("z", true): model.redo(); return true
            case ("a", false): pane.selectAll(); return true
            case ("d", false): model.duplicate(pane.selectedURLs); return true
            case ("n", true): model.newFolder(in: pane); return true
            case ("c", false): model.copyToPasteboard(pane.selectedURLs); return true
            case ("v", false): model.paste(into: pane.current, move: option); return true
            case ("m", true): model.sendToOtherPane(copy: false); return true
            case ("c", true): model.sendToOtherPane(copy: true); return true
            case ("r", false): pane.reload(); return true
            case ("r", true): model.sheet = .rules; return true
            case ("[", _): pane.goBack(); return true
            case ("]", _): pane.goForward(); return true
            case ("\\", _):
                model.twoPane.toggle()
                preview?.fitToPaneCount()
                return true
            case ("1", false): pane.viewMode = .grid; return true
            case ("2", false): pane.viewMode = .list; return true
            default: break
            }
            switch code {
            case kVK_UpArrow: pane.goUp(); return true
            case kVK_DownArrow: pane.enterSelection(); return true
            case kVK_Delete, kVK_ForwardDelete: model.trash(pane.selectedURLs); return true
            default: return false
            }
        }

        switch code {
        case kVK_Space:
            preview?.togglePreview(); return true
        case kVK_UpArrow: pane.moveFocus(.up, extend: shift); return true
        case kVK_DownArrow: pane.moveFocus(.down, extend: shift); return true
        case kVK_LeftArrow: pane.moveFocus(.left, extend: shift); return true
        case kVK_RightArrow: pane.moveFocus(.right, extend: shift); return true
        case kVK_Home: pane.moveFocus(.home, extend: shift); return true
        case kVK_End: pane.moveFocus(.end, extend: shift); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            let selected = pane.selectedURLs
            if shift, selected.count > 1 { model.beginBatchRename(selected) }
            else if shift, let url = selected.first { pane.renaming = url }
            else { pane.openSelection() }
            return true
        case kVK_Delete, kVK_ForwardDelete:
            model.trash(pane.selectedURLs); return true
        case kVK_Tab:
            if model.panes.count > 1 { model.activePaneIndex = model.activePaneIndex == 0 ? 1 : 0 }
            return true
        case kVK_Escape:
            if pane.isVirtual { pane.closeVirtualView() }
            else if pane.filter.isActive { pane.filter.reset() }
            else if !pane.selection.isEmpty { pane.clearSelection() }
            else { preview?.hide() }
            return true
        default:
            break
        }

        // 1-9 send the selection to that target.
        if flags.subtracting([.numericPad, .function, .capsLock]).isEmpty,
           let digit = Int(key), (1...9).contains(digit) {
            model.send(toTarget: digit - 1)
            return true
        }
        return false
    }
}
