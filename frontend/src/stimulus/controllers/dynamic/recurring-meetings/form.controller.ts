import OpMeetingsFormController from 'core-stimulus/controllers/dynamic/meetings/form.controller';

export default class OpRecurringMeetingsFormController extends OpMeetingsFormController {
  static values = {
    persisted: Boolean,
  };

  declare persistedValue:boolean;

  updateFrequencyText():void {
    const data = new FormData(this.element as HTMLFormElement);
    const urlSearchParams = new URLSearchParams();
    [
      'start_date',
      'start_time_hour',
      'frequency',
      'interval',
      'time_zone',
      'end_after',
      'end_date',
      'iterations',
      'preset',
      'schedule_mode_option',
      'week_ordinal',
      'weekday',
    ].forEach((name) => {
      const key = `meeting[${name}]`;
      const value = data.get(key);
      if (value !== null) {
        urlSearchParams.append(key, value as string);
      }
    });

    data.getAll('meeting[weekdays][]').forEach((value) => {
      urlSearchParams.append('meeting[weekdays][]', value as string);
    });

    void this
      .turboRequests
      .request(
        `${this.pathHelper.staticBase}/recurring_meetings/humanize_schedule?${urlSearchParams.toString()}`,
        {
          headers: {
            Accept: 'text/vnd.turbo-stream.html',
          },
        },
      );
  }

  updateTimezoneText() {
    // We don't update the timezone text on editing recurring meetings
    if (this.persistedValue) {
      return;
    }

    super.updateTimezoneText();
  }
}
