/*
 * Fill Terminus's Models -> New form for a reMarkable Paper Pure.
 *
 * Run this in the browser developer console while the New Model form is open.
 * It never submits the form. Review every value, then click Save yourself.
 *
 * This is intentionally tracked: it contains reusable device facts only, no
 * private hostnames, device identifiers, credentials, or account information.
 */
(() => {
  "use strict";

  const values = {
    model_label: "reMarkable Paper Pure",
    model_name: "remarkable_paper_pure",
    model_description: "reMarkable Paper Pure via Paperboard (landscape)",
    model_mime_type: "image/png",
    model_colors: "16",
    model_bit_depth: "4",
    model_rotation: "0",
    model_offset_x: "0",
    model_offset_y: "0",
    model_scale_factor: "1.8",
    model_width: "1872",
    model_height: "1404",
  };

  const setValue = (id, value) => {
    const element = document.getElementById(id);
    if (!(element instanceof HTMLInputElement)) {
      throw new Error(`Terminus field #${id} was not found. Open Models -> New and try again.`);
    }

    const prototype = Object.getPrototypeOf(element);
    const setter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
    if (setter) setter.call(element, value);
    else element.value = value;

    element.dispatchEvent(new Event("input", { bubbles: true }));
    element.dispatchEvent(new Event("change", { bubbles: true }));
  };

  Object.entries(values).forEach(([id, value]) => setValue(id, value));

  const palette = document.getElementById("model_default_palette_id");
  if (!(palette instanceof HTMLSelectElement)) {
    throw new Error("Terminus palette field was not found. The other fields were filled; do not save yet.");
  }

  const gray16 = [...palette.options].find((option) =>
    /(?:16\s*grays?|gray.?16|4.?bit)/i.test(option.textContent ?? "")
  );

  if (gray16) {
    palette.value = gray16.value;
    palette.dispatchEvent(new Event("input", { bubbles: true }));
    palette.dispatchEvent(new Event("change", { bubbles: true }));
  }

  const form = document.getElementById("model_label")?.closest("form");
  if (form) {
    form.style.outline = "4px solid #ff654a";
    form.style.outlineOffset = "8px";
  }

  console.table({
    ...values,
    model_default_palette: gray16?.textContent?.trim() ?? "NOT SET - choose 16 Grays (4-bit) manually",
    model_css: "left unchanged (optional)",
    submitted: "no",
  });
  console.info("Paper Pure values filled. Review the form, then click Save manually.");
})();
