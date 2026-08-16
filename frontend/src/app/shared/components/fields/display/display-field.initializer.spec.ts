import {
  DisplayFieldService,
  IDisplayFieldType,
} from 'core-app/shared/components/fields/display/display-field.service';
import { initializeCoreDisplayFields } from 'core-app/shared/components/fields/display/display-field.initializer';
import {
  ResourceDisplayField,
} from 'core-app/shared/components/fields/display/field-types/resource-display-field.module';

describe('initializeCoreDisplayFields', () => {
  let service:DisplayFieldService;

  beforeEach(() => {
    service = new DisplayFieldService();
    initializeCoreDisplayFields(service)();
  });

  // Department custom fields are typed "Department" in the API schema. Without a registered
  // display field they fall back to the text display, which stringifies the HalResource
  // to "[HalResource href=...]".
  it('maps the Department schema type to the resource display field', () => {
    expect(service.getClassFor('customField262', 'Department')).toBe(ResourceDisplayField as unknown as IDisplayFieldType);
  });
});
