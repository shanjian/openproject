import * as Turbo from '@hotwired/turbo';
import TurboPower from 'turbo_power';
import { registerDialogStreamAction } from './dialog-stream-action';
import { addTurboEventListeners } from './turbo-event-listeners';
import { registerFlashStreamAction } from './flash-stream-action';
import { registerLiveRegionStreamAction } from './live-region-stream-action';
import { registerInputCaptionStreamAction } from './input-caption-stream-action';
import { addTurboGlobalListeners } from './turbo-global-listeners';
import { applyTurboNavigationPatch } from './turbo-navigation-patch';
import { debugLog, whenDebugging } from 'core-app/shared/helpers/debug_output';
import { TURBO_EVENTS } from './constants';
import { StreamActions } from '@hotwired/turbo';
import { addTurboAngularWrapper } from 'core-turbo/turbo-angular-wrapper';

Turbo.session.drive = true;
Turbo.config.drive.progressBarDelay = 100;

// Start turbo
Turbo.start();

// Register logging of events
whenDebugging(() => {
  TURBO_EVENTS
    .filter((name) => name !== 'turbo:before-stream-render')
    .forEach((name:string) => {
    document.addEventListener(name, (event) => {
      debugLog(`[TURBO EVENT ${name}] %O`, event);
    });
  });

  document.addEventListener('turbo:before-stream-render', (event) => {
    const { detail: { newStream:stream } } = event;
    debugLog(`[TURBO EVENT turbo-before-stream-render] ${stream.action.toUpperCase()} target=${stream.target} %O`, event);
  });
});

// Register our own actions
addTurboEventListeners();
addTurboGlobalListeners();
registerDialogStreamAction();
registerFlashStreamAction();
registerLiveRegionStreamAction();
registerInputCaptionStreamAction();
addTurboAngularWrapper();

StreamActions.reloadPage = function reloadPage() {
  window.location.reload();
};

// Apply navigational patch
// https://github.com/hotwired/turbo/issues/1300
applyTurboNavigationPatch();

// Register only the turbo-power stream actions we actually use
TurboPower.register('push_state', TurboPower.Actions.push_state, StreamActions);
TurboPower.register('turbo_frame_set_src', TurboPower.Actions.turbo_frame_set_src, StreamActions);
TurboPower.register('redirect_to', TurboPower.Actions.redirect_to, StreamActions);
TurboPower.register('set_dataset_attribute', TurboPower.Actions.set_dataset_attribute, StreamActions);
TurboPower.register('set_title', TurboPower.Actions.set_title, StreamActions);
// Used by OpTurbo::ComponentStream#scroll_into_view_via_turbo_stream (e.g. meeting outcomes,
// SAML/OIDC provider forms). It only scrolls an element into view: no navigation, no form submission.
TurboPower.register('scroll_into_view', TurboPower.Actions.scroll_into_view, StreamActions);

// Error handling when "Content missing" returned
document.addEventListener('turbo:frame-missing', (event) => {
  const { detail: { response, visit } } = event;
  event.preventDefault();
  void visit(response.url, {});
});
