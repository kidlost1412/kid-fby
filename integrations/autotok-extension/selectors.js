// All TikTok Studio selectors live here (E8). Each key lists several candidates, tried in order:
//   css:  CSS selectors (data-e2e first, then structural/aria)
//   text: {tags, re} - visible element of one of `tags` whose trimmed text matches `re` (vi + en)
// None of these were verified against the live page yet: the P0 self-test reports which ones matched.
(function () {
  const T = (tags, re) => ({ tags, re });
  const SEL = {
    fileInput: {
      css: ['input[type="file"][accept*="video"]', 'input[type="file"]'],
    },
    editor: {
      css: [
        '[data-e2e="caption_container"] [contenteditable="true"]',
        '.public-DraftEditor-content[contenteditable="true"]',
        '.caption-editor [contenteditable="true"]',
        'div[contenteditable="true"][role="combobox"]',
        'div[contenteditable="true"]',
      ],
    },
    hashtagPopup: {
      css: ['[data-e2e="hashtag-suggestion"]', '.mention-list', '[class*="mention"] [role="listbox"]', '[role="listbox"]'],
    },
    postButton: {
      css: ['button[data-e2e="post_video_button"]', '[data-e2e="post_video_button"]', 'button[data-e2e*="post"]'],
      text: [T('button', /^(post|đăng|đăng bài|schedule|lên lịch)$/i)],
    },
    // Dialog button shown after pressing Post (content check / "post now" confirmations)
    confirmPostButton: {
      css: ['[role="dialog"] button[data-e2e*="confirm"]', '[data-e2e="confirm_post_button"]'],
      text: [T('[role="dialog"] button, .TUXModal button, [class*="modal"] button', /^(post now|đăng ngay|đăng|publish|post|continue|tiếp tục)$/i)],
    },
    uploadedMarker: {
      // Something that only exists once the file is attached (replace/remove/preview)
      css: ['[data-e2e="upload_status_container"]', '[data-e2e="file_name"]', '[class*="uploaded"]', 'video'],
      text: [T('button, span, div', /^(replace|thay thế|change video|đổi video)$/i)],
    },
    cancelUpload: {
      css: ['[data-e2e*="cancel"]'],
      text: [T('button, span, div', /^(cancel|hủy|huỷ|hủy tải lên|cancel upload)$/i)],
    },
    uploadBusy: {
      css: ['[role="progressbar"]', '[class*="progress"]:not([class*="progress-bar-bg"])'],
      text: [T('span, div', /(uploading|đang tải lên|processing|đang xử lý)/i)],
    },
    visibilityDropdown: {
      css: ['[data-e2e="video_visibility_container"]', '[data-e2e*="visibility"]', '[data-e2e*="privacy"]', 'div[role="combobox"]'],
      text: [T('div, button', /^(everyone|public|mọi người|công khai|friends|bạn bè|only me|private|chỉ mình tôi|riêng tư)$/i)],
    },
    visibilityOptions: {
      public: [T('[role="option"], li, div, span', /^(everyone|public|mọi người|công khai)$/i)],
      friends: [T('[role="option"], li, div, span', /^(friends|bạn bè)$/i)],
      private: [T('[role="option"], li, div, span', /^(only me|only you|private|chỉ mình tôi|riêng tư)$/i)],
    },
    scheduleToggle: {
      css: ['[data-e2e="schedule_toggle"]', 'input[type="radio"][value="schedule"]', 'input[type="radio"][value="scheduled"]'],
      text: [T('label, [role="radio"], div, span', /^(schedule|lên lịch|hẹn giờ|lên lịch đăng)$/i)],
    },
    scheduleDate: {
      css: ['[data-e2e="schedule_date"]', '[data-e2e*="date"] input', 'input[type="text"][value*="-"]'],
    },
    scheduleTime: {
      css: ['[data-e2e="schedule_time"]', '[data-e2e*="time"] input', 'input[type="text"][value*=":"]'],
    },
    calendarDay: {
      css: ['.calendar-wrapper .day.valid', '[role="gridcell"]:not([aria-disabled="true"])', '[class*="calendar"] [class*="day"]'],
    },
    calendarNext: {
      css: ['[data-e2e="calendar_next"]', '[aria-label*="Next"]', '[aria-label*="Tiếp"]', '.calendar-wrapper .arrow:last-child', '.calendar-wrapper [class*="arrow"]:last-of-type'],
    },
    calendarPrev: {
      css: ['[data-e2e="calendar_prev"]', '[aria-label*="Prev"]', '[aria-label*="Trước"]', '.calendar-wrapper .arrow:first-child', '.calendar-wrapper [class*="arrow"]:first-of-type'],
    },
    timeHourOption: { css: ['.tiktok-timepicker-left .tiktok-timepicker-option-text', '[class*="timepicker"] [class*="left"] [class*="option"]'] },
    timeMinuteOption: { css: ['.tiktok-timepicker-right .tiktok-timepicker-option-text', '[class*="timepicker"] [class*="right"] [class*="option"]'] },
    // Account identity in the page (DOM fallback; see content.js for the JSON sources)
    accountLink: {
      css: ['a[href^="/@"]', '[data-e2e="profile-icon"]', '[data-e2e*="avatar"]', '[data-e2e*="user"]'],
    },
  };

  const visible = (el) => !!el && el.getClientRects().length > 0;

  function byText(spec, root) {
    const out = [];
    for (const el of root.querySelectorAll(spec.tags)) {
      if (!visible(el)) continue;
      const t = (el.textContent || '').trim();
      if (t && t.length <= 60 && spec.re.test(t)) out.push(el);
    }
    // Prefer the innermost match (a parent div with the same text also matches).
    return out.filter((el) => !out.some((o) => o !== el && el.contains(o)));
  }

  // -> {els: [...], via: 'css:...' | 'text:...' | null}
  function findAll(key, root, sub) {
    root = root || document;
    let def = SEL[key];
    if (sub) def = { text: def[sub] };
    if (!def) return { els: [], via: null };
    for (const c of def.css || []) {
      let els = [];
      try { els = [...root.querySelectorAll(c)]; } catch (_) { /* invalid selector for this engine */ }
      if (els.length) return { els, via: 'css:' + c };
    }
    for (const spec of def.text || []) {
      const els = byText(spec, root);
      if (els.length) return { els, via: 'text:' + spec.tags + ' ' + spec.re };
    }
    return { els: [], via: null };
  }

  const find = (key, root, sub) => { const r = findAll(key, root, sub); return { el: r.els[0] || null, via: r.via }; };

  function describe(el) {
    if (!el) return null;
    const a = (n) => el.getAttribute(n);
    return {
      tag: el.tagName.toLowerCase(),
      e2e: a('data-e2e'), role: a('role'), aria: a('aria-label'), type: a('type'),
      cls: String(a('class') || '').slice(0, 80),
      text: (el.textContent || '').trim().slice(0, 60),
      disabled: el.disabled === true || a('aria-disabled') === 'true',
    };
  }

  // DOM summary of every key (used by self-test / failures)
  function report(root) {
    const out = {};
    for (const key of Object.keys(SEL)) {
      if (key === 'visibilityOptions') {
        for (const sub of Object.keys(SEL.visibilityOptions)) {
          const r = findAll(key, root, sub);
          out['visibilityOptions.' + sub] = { found: r.els.length, via: r.via, first: describe(r.els[0]) };
        }
        continue;
      }
      const r = findAll(key, root);
      out[key] = { found: r.els.length, via: r.via, first: describe(r.els[0]) };
    }
    return out;
  }

  self.AutotokSel = { SEL, find, findAll, describe, report, visible };
})();
