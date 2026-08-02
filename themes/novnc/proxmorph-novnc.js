/**
 * ProxMorph noVNC Clipboard
 *
 * Enhances Proxmox's supported noVNC clipboard transport without replacing it.
 * Clipboard text remains in memory only and is cleared when the console closes.
 *
 * Version: 1.0.0
 */
(function () {
    'use strict';

    var VERSION = '1.0.0';
    var PREFERENCES_URL = '/api2/extjs/proxmorph/preferences';
    var COPY_TIMEOUT_MS = 1800;
    var defaults = {
        noVncContextMenu: true,
        noVncClipboardShortcuts: false,
    };
    var settings = copySettings(defaults);
    var clipboardButton = null;
    var clipboardPanel = null;
    var clipboardText = null;
    var canvas = null;
    var container = null;
    var contextMenu = null;
    var panelStatus = null;
    var menuStatus = null;
    var boundRfb = null;
    var bindTimer = null;
    var copyTimer = null;
    var copyPending = false;
    var consoleFocused = false;
    var lastGuestText = '';
    var availabilityState = null;

    function copySettings(source) {
        return {
            noVncContextMenu: source.noVncContextMenu,
            noVncClipboardShortcuts: source.noVncClipboardShortcuts,
        };
    }

    function normalizeBoolean(value) {
        return (
            value === true ||
            value === 1 ||
            value === '1' ||
            value === 'true' ||
            value === 'on'
        );
    }

    function normalizePreferences(values) {
        var normalized = copySettings(defaults);
        Object.keys(normalized).forEach(function (key) {
            if (Object.prototype.hasOwnProperty.call(values || {}, key)) {
                normalized[key] = normalizeBoolean(values[key]);
            }
        });
        return normalized;
    }

    function getCookie(name) {
        var prefix = name + '=';
        var cookies = (document.cookie || '').split(';');
        for (var index = 0; index < cookies.length; index++) {
            var cookie = cookies[index].trim();
            if (cookie.indexOf(prefix) === 0) {
                return decodeURIComponent(cookie.slice(prefix.length));
            }
        }
        return '';
    }

    function loadActiveTheme() {
        var themeKey = getCookie('PVEThemeCookie');
        if (!/^[a-z]{1,10}(?:-[a-z]{1,10}){0,5}$/.test(themeKey)) {
            return;
        }
        if (document.getElementById('proxmorph-novnc-active-theme')) {
            return;
        }

        var link = document.createElement('link');
        link.id = 'proxmorph-novnc-active-theme';
        link.rel = 'stylesheet';
        link.href = '/pwt/themes/theme-' + themeKey + '.css';
        document.head.appendChild(link);
    }

    function loadPreferences() {
        if (typeof window.fetch !== 'function') {
            return Promise.resolve(copySettings(settings));
        }

        return window
            .fetch(PREFERENCES_URL, {
                credentials: 'same-origin',
                headers: { Accept: 'application/json' },
            })
            .then(function (response) {
                if (!response.ok) {
                    throw new Error('HTTP ' + response.status);
                }
                return response.json();
            })
            .then(function (payload) {
                var values = payload && (payload.data || (payload.result && payload.result.data));
                settings = normalizePreferences(values || {});
                updatePreferenceSummary();
                return copySettings(settings);
            })
            .catch(function () {
                settings = copySettings(defaults);
                updatePreferenceSummary();
                return copySettings(settings);
            });
    }

    function clipboardAvailable() {
        return Boolean(
            clipboardButton &&
                !clipboardButton.classList.contains('pve_hidden') &&
                boundRfb &&
                window.ProxMorphNoVNCUI &&
                window.ProxMorphNoVNCUI.connected,
        );
    }

    function isEditableTarget(target) {
        if (!target || !target.closest) {
            return false;
        }
        return Boolean(target.closest('input, textarea, select, button, [contenteditable="true"]'));
    }

    function shortcutAction(event) {
        if (!event || (!event.ctrlKey && !event.metaKey) || event.altKey || event.shiftKey) {
            return '';
        }
        var key = String(event.key || '').toLowerCase();
        return key === 'c' || key === 'v' ? key : '';
    }

    function setStatus(message, state) {
        var className = 'pmx-novnc-status pmx-novnc-status-' + (state || 'info');
        [panelStatus, menuStatus].forEach(function (element) {
            if (!element) {
                return;
            }
            element.className = className;
            element.textContent = message;
        });
    }

    function updatePreferenceSummary() {
        var summary = document.getElementById('pmx_novnc_preference_summary');
        if (!summary) {
            return;
        }
        summary.textContent = settings.noVncClipboardShortcuts
            ? 'Ctrl+C and Ctrl+V capture is enabled for this account.'
            : 'Ctrl+C and Ctrl+V continue to pass directly to the guest.';
    }

    function updateAvailability(force) {
        var available = clipboardAvailable();
        if (!force && available === availabilityState) {
            return;
        }
        availabilityState = available;
        var buttons = document.querySelectorAll('[data-pmx-clipboard-action]');
        buttons.forEach(function (button) {
            var action = button.getAttribute('data-pmx-clipboard-action');
            button.disabled = !available && action !== 'open';
        });

        if (!available) {
            setStatus('Enable VNC clipboard on the VM display and install the guest vdagent.', 'warning');
        } else if (!copyPending) {
            setStatus('Clipboard transport is ready. Text is never saved by ProxMorph.', 'ready');
        }
    }

    function openClipboardPanel() {
        if (!clipboardButton || !clipboardPanel) {
            return;
        }
        if (clipboardButton.classList.contains('pve_hidden')) {
            setStatus('VNC clipboard is not enabled for this guest.', 'warning');
            return;
        }
        hideContextMenu();
        if (!clipboardPanel.classList.contains('noVNC_open')) {
            clipboardButton.click();
        }
    }

    function focusClipboardText() {
        openClipboardPanel();
        if (clipboardText) {
            clipboardText.focus();
            clipboardText.select();
        }
    }

    function sendClipboardText(text) {
        if (!clipboardAvailable() || !clipboardText) {
            setStatus('VNC clipboard is not available for this guest.', 'warning');
            return false;
        }
        clipboardText.value = text;
        clipboardText.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
    }

    function sendGuestShortcut(letter) {
        if (!boundRfb) {
            return;
        }
        var keysym = letter === 'c' ? 0x0063 : 0x0076;
        var code = letter === 'c' ? 'KeyC' : 'KeyV';
        boundRfb.sendKey(0xffe3, 'ControlLeft', true);
        boundRfb.sendKey(keysym, code, true);
        boundRfb.sendKey(keysym, code, false);
        boundRfb.sendKey(0xffe3, 'ControlLeft', false);
        boundRfb.focus();
    }

    function copyToBrowser(text, automatic) {
        var value = typeof text === 'string' ? text : lastGuestText;
        if (!navigator.clipboard || typeof navigator.clipboard.writeText !== 'function') {
            focusClipboardText();
            setStatus('Browser clipboard access is unavailable. The text is selected for manual copy.', 'warning');
            return Promise.resolve(false);
        }

        return navigator.clipboard
            .writeText(value)
            .then(function () {
                setStatus(automatic ? 'Guest clipboard copied to the browser.' : 'Copied to browser clipboard.', 'ready');
                return true;
            })
            .catch(function () {
                focusClipboardText();
                setStatus('The browser blocked clipboard access. The text is selected for manual copy.', 'warning');
                return false;
            });
    }

    function finishCopyRequest(text) {
        if (!copyPending) {
            return;
        }
        copyPending = false;
        window.clearTimeout(copyTimer);
        copyTimer = null;
        copyToBrowser(text, true);
    }

    function requestGuestCopy() {
        if (!clipboardAvailable()) {
            setStatus('VNC clipboard is not available for this guest.', 'warning');
            return;
        }
        copyPending = true;
        setStatus('Requesting the selected text from the guest…', 'working');
        sendGuestShortcut('c');
        window.clearTimeout(copyTimer);
        copyTimer = window.setTimeout(function () {
            if (!copyPending) {
                return;
            }
            copyPending = false;
            setStatus('No new guest clipboard text arrived. Copy inside the guest, then try again.', 'warning');
        }, COPY_TIMEOUT_MS);
    }

    function pasteFromBrowser() {
        if (!clipboardAvailable()) {
            setStatus('VNC clipboard is not available for this guest.', 'warning');
            return Promise.resolve(false);
        }
        if (!navigator.clipboard || typeof navigator.clipboard.readText !== 'function') {
            focusClipboardText();
            setStatus('Paste into the clipboard field, then return to the console.', 'warning');
            return Promise.resolve(false);
        }

        setStatus('Reading browser clipboard…', 'working');
        return navigator.clipboard
            .readText()
            .then(function (text) {
                if (!sendClipboardText(text)) {
                    return false;
                }
                sendGuestShortcut('v');
                setStatus('Pasted browser clipboard into the guest.', 'ready');
                hideContextMenu();
                return true;
            })
            .catch(function () {
                focusClipboardText();
                setStatus('The browser blocked clipboard access. Paste into the selected field instead.', 'warning');
                return false;
            });
    }

    function clearClipboard() {
        lastGuestText = '';
        if (clipboardAvailable()) {
            sendClipboardText('');
        } else if (clipboardText) {
            clipboardText.value = '';
        }
        setStatus('Console clipboard cleared.', 'ready');
        hideContextMenu();
    }

    function handleAction(action) {
        if (action === 'paste') {
            pasteFromBrowser();
        } else if (action === 'copy') {
            requestGuestCopy();
        } else if (action === 'open') {
            openClipboardPanel();
        } else if (action === 'clear') {
            clearClipboard();
        }
    }

    function actionButton(action, label) {
        var button = document.createElement('button');
        button.type = 'button';
        button.className = 'pmx-novnc-action';
        button.setAttribute('data-pmx-clipboard-action', action);
        button.textContent = label;
        button.addEventListener('click', function () {
            handleAction(action);
        });
        return button;
    }

    function createPanelEnhancement() {
        if (!clipboardPanel || document.getElementById('pmx_novnc_clipboard_actions')) {
            return;
        }

        var enhancement = document.createElement('div');
        enhancement.id = 'pmx_novnc_clipboard_actions';
        enhancement.className = 'pmx-novnc-enhancement';

        var actions = document.createElement('div');
        actions.className = 'pmx-novnc-actions';
        actions.appendChild(actionButton('paste', 'Paste into guest'));
        actions.appendChild(actionButton('copy', 'Copy from guest'));
        actions.appendChild(actionButton('clear', 'Clear'));

        panelStatus = document.createElement('div');
        panelStatus.className = 'pmx-novnc-status pmx-novnc-status-info';
        panelStatus.setAttribute('role', 'status');

        var summary = document.createElement('p');
        summary.id = 'pmx_novnc_preference_summary';
        summary.className = 'pmx-novnc-preference-summary';

        var hint = document.createElement('p');
        hint.className = 'pmx-novnc-hint';
        hint.textContent = 'Shift + right-click the console for clipboard actions. Normal right-click still goes to the guest.';

        enhancement.appendChild(actions);
        enhancement.appendChild(panelStatus);
        enhancement.appendChild(summary);
        enhancement.appendChild(hint);
        clipboardPanel.appendChild(enhancement);
        updatePreferenceSummary();
    }

    function createContextMenu() {
        if (contextMenu) {
            return;
        }
        contextMenu = document.createElement('div');
        contextMenu.id = 'pmx_novnc_context_menu';
        contextMenu.className = 'pmx-novnc-context-menu';
        contextMenu.setAttribute('role', 'menu');
        contextMenu.setAttribute('aria-label', 'Console clipboard');

        var heading = document.createElement('div');
        heading.className = 'pmx-novnc-context-heading';
        heading.textContent = 'Console clipboard';
        contextMenu.appendChild(heading);
        contextMenu.appendChild(actionButton('paste', 'Paste into guest'));
        contextMenu.appendChild(actionButton('copy', 'Copy from guest'));
        contextMenu.appendChild(actionButton('open', 'Open clipboard panel'));
        contextMenu.appendChild(actionButton('clear', 'Clear clipboard'));

        menuStatus = document.createElement('div');
        menuStatus.className = 'pmx-novnc-status pmx-novnc-status-info';
        menuStatus.setAttribute('role', 'status');
        contextMenu.appendChild(menuStatus);
        document.body.appendChild(contextMenu);
    }

    function showContextMenu(clientX, clientY) {
        createContextMenu();
        updateAvailability(true);
        contextMenu.classList.add('pmx-novnc-context-menu-open');

        var width = contextMenu.offsetWidth || 260;
        var height = contextMenu.offsetHeight || 220;
        var left = Math.min(clientX, Math.max(8, window.innerWidth - width - 8));
        var top = Math.min(clientY, Math.max(8, window.innerHeight - height - 8));
        contextMenu.style.left = Math.max(8, left) + 'px';
        contextMenu.style.top = Math.max(8, top) + 'px';
        var firstButton = contextMenu.querySelector('button:not([disabled])');
        if (firstButton) {
            firstButton.focus();
        }
    }

    function hideContextMenu() {
        if (contextMenu) {
            contextMenu.classList.remove('pmx-novnc-context-menu-open');
        }
    }

    function handleConsoleContextMenu(event) {
        if (!settings.noVncContextMenu || !event.shiftKey) {
            return;
        }
        event.preventDefault();
        event.stopImmediatePropagation();
        showContextMenu(event.clientX, event.clientY);
    }

    function handleShortcut(event) {
        var action = shortcutAction(event);
        if (
            !settings.noVncClipboardShortcuts ||
            !consoleFocused ||
            !action ||
            isEditableTarget(event.target)
        ) {
            return;
        }

        event.preventDefault();
        event.stopImmediatePropagation();
        if (action === 'c') {
            requestGuestCopy();
        } else {
            pasteFromBrowser();
        }
    }

    function handleClipboardEvent(event) {
        lastGuestText = event && event.detail && typeof event.detail.text === 'string'
            ? event.detail.text
            : '';
        if (clipboardText) {
            clipboardText.value = lastGuestText;
        }
        finishCopyRequest(lastGuestText);
    }

    function clearTransientState() {
        lastGuestText = '';
        copyPending = false;
        consoleFocused = false;
        window.clearTimeout(copyTimer);
        copyTimer = null;
        hideContextMenu();
        if (clipboardText) {
            clipboardText.value = '';
        }
    }

    function bindRfb() {
        var ui = window.ProxMorphNoVNCUI;
        var rfb = ui && ui.rfb;
        if (!rfb || rfb === boundRfb) {
            updateAvailability();
            return;
        }

        if (boundRfb) {
            boundRfb.removeEventListener('clipboard', handleClipboardEvent);
            boundRfb.removeEventListener('disconnect', clearTransientState);
        }
        boundRfb = rfb;
        boundRfb.addEventListener('clipboard', handleClipboardEvent);
        boundRfb.addEventListener('disconnect', clearTransientState);
        updateAvailability();
    }

    function initialize() {
        clipboardButton = document.getElementById('noVNC_clipboard_button');
        clipboardPanel = document.getElementById('noVNC_clipboard');
        clipboardText = document.getElementById('noVNC_clipboard_text');
        canvas = document.getElementById('noVNC_canvas');
        container = document.getElementById('noVNC_container');

        if (!clipboardButton || !clipboardPanel || !clipboardText || !canvas || !container) {
            return;
        }

        document.documentElement.classList.add('proxmorph-novnc');
        loadActiveTheme();
        createPanelEnhancement();
        createContextMenu();
        loadPreferences();

        canvas.addEventListener('contextmenu', handleConsoleContextMenu, true);
        container.addEventListener('pointerdown', function () {
            consoleFocused = true;
        });
        document.addEventListener('pointerdown', function (event) {
            if (!container.contains(event.target) && (!contextMenu || !contextMenu.contains(event.target))) {
                consoleFocused = false;
                hideContextMenu();
            }
        });
        document.addEventListener('keydown', function (event) {
            if (event.key === 'Escape') {
                hideContextMenu();
            }
        });
        window.addEventListener('keydown', handleShortcut, true);
        window.addEventListener('blur', hideContextMenu);
        window.addEventListener('beforeunload', clearTransientState);

        var buttonObserver = new MutationObserver(function () {
            updateAvailability();
        });
        buttonObserver.observe(clipboardButton, { attributes: true, attributeFilter: ['class'] });
        bindRfb();
        bindTimer = window.setInterval(bindRfb, 400);
        updateAvailability();
    }

    window.ProxMorphNoVNCClipboard = {
        version: VERSION,
        defaults: copySettings(defaults),
        normalizePreferences: normalizePreferences,
        shortcutAction: shortcutAction,
        clearTransientState: clearTransientState,
        stop: function () {
            window.clearInterval(bindTimer);
            clearTransientState();
        },
    };

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initialize, { once: true });
    } else {
        initialize();
    }
})();
