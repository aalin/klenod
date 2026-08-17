import IntlTime from "./IntlTime.tsx";
import styles from "./TimeDemo.css";
import orbit from "./orbit.svg";
import coffee from "../assets/coffee.jpg";

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
      styles.style(),
      <dl class="assets">
        <dt>Imported SVG</dt>
        <dd>
          <img src={orbit.src} width={orbit.width} height={orbit.height} alt="" />
        </dd>
        <dt>Imported image</dt>
        <dd>
          <img src={coffee.src} width={160} height={Math.round(160 * coffee.height / coffee.width)} alt="" />
        </dd>
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
