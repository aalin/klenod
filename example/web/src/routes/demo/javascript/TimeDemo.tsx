import IntlTime from "./IntlTime.tsx";

const Locales = [
  ["en-US", "United States"],
  ["sv-SE", "Sweden"],
  ["ja-JP", "Japan"],
  ["ar-EG", "Egypt"],
];

export default class TimeDemoElement extends HTMLElement {
  static get observedAttributes(): string[] {
    return ["time"];
  }

  connectedCallback(): void {
    this.render();
  }

  attributeChangedCallback(): void {
    if (this.isConnected) this.render();
  }

  render(): void {
    const time = this.getAttribute("time");
    if (!time) return;

    this.replaceChildren(
      <dl>
        {Locales.map(([locale, label]) => (
          <>
            <dt>{label}</dt>
            <dd>
              <IntlTime lang={locale} time={time} date-style="full" time-style="long">
                {time}
              </IntlTime>
            </dd>
          </>
        ))}
      </dl>
    );
  }
}
