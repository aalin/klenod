class IntlTimeElement extends HTMLTimeElement {
  static get observedAttributes() {
    return ['datetime', 'lang', 'date-style', 'time-style'];
  }

  connectedCallback() {
    this.render();
  }

  attributeChangedCallback() {
    if (this.isConnected) this.render();
  }

  render() {
    const datetime = this.getAttribute('datetime');
    if (!datetime) return;

    const date = new Date(datetime);
    if (Number.isNaN(date.getTime())) return;

    const options = this.formatOptions();
    const formatter = new Intl.DateTimeFormat(this.locale(), options);

    this.textContent = formatter.format(date);
  }

  locale() {
    return this.getAttribute('lang') || navigator.language;
  }

  formatOptions() {
    const options = {};
    const dateStyle = this.getAttribute('date-style');
    const timeStyle = this.getAttribute('time-style');

    if (dateStyle) options.dateStyle = dateStyle;
    if (timeStyle) options.timeStyle = timeStyle;

    return options;
  }
}

customElements.define('intl-time', IntlTimeElement, { extends: 'time' });
