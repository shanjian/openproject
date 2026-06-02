import { InjectionToken } from '@angular/core';

export const OpContextMenuLocalsToken = new InjectionToken<any>('CONTEXT_MENU_LOCALS');

export interface OpContextMenuItem {
  disabled?:boolean;
  hidden?:boolean;
  icon?:string;
  // Trailing icon (rendered after the label), e.g. a state checkmark. The
  // template already supports `postIcon`/`postIconTitle`; declared here so
  // callers are type-checked.
  postIcon?:string;
  postIconTitle?:string;
  href?:string;
  class?:string;
  ariaLabel?:string;
  linkText?:string;
  title?:string;
  divider?:boolean;
  isHeader?:boolean;
  onClick?:(event:MouseEvent) => boolean;
}

export interface OpContextMenuLocalsMap {
  items:OpContextMenuItem[];
  showAnchorRight?:boolean;
  contextMenuId?:string;
  label?:string;
  /* eslint-disable @typescript-eslint/no-explicit-any */
  [key:string]:any;
}
