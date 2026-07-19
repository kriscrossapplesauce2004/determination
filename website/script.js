const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;

const wipe = document.createElement('div');
wipe.className = 'page-wipe';
wipe.setAttribute('aria-hidden', 'true');
document.body.appendChild(wipe);

if (!reduce && sessionStorage.getItem('determination-transition') === '1') {
  sessionStorage.removeItem('determination-transition');
  wipe.classList.add('arriving');
}

document.querySelectorAll('a[href]').forEach(link => {
  const target = new URL(link.href, location.href);
  const localPage = target.origin === location.origin && target.pathname !== location.pathname;
  if (!localPage || reduce) return;
  link.addEventListener('click', event => {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    sessionStorage.setItem('determination-transition', '1');
    wipe.classList.add('leaving');
    setTimeout(() => { location.href = target.href; }, 410);
  });
});

const boot = document.querySelector('.boot');
if (boot && !reduce) {
  document.body.classList.add('is-booting');
  const number = boot.querySelector('b');
  const bar = boot.querySelector('.boot-bar i');
  const status = boot.querySelector('.boot-status');
  const started = performance.now();
  const bootTick = now => {
    const progress = Math.min((now - started) / 620, 1);
    const value = Math.round(progress * 100);
    number.textContent = String(value).padStart(3, '0');
    bar.style.transform = `scaleX(${progress})`;
    if (value > 38) status.textContent = 'ACQUIRING HARDWARE';
    if (value > 76) status.textContent = 'DETERMINED';
    if (progress < 1) requestAnimationFrame(bootTick);
    else {
      boot.classList.add('done');
      document.body.classList.remove('is-booting');
    }
  };
  requestAnimationFrame(bootTick);
} else if (boot) {
  boot.remove();
}

const observer = new IntersectionObserver((entries) => {
  entries.forEach((entry) => {
    if (!entry.isIntersecting) return;
    entry.target.classList.add('visible');
    entry.target.querySelectorAll?.('[data-target]').forEach(count);
    observer.unobserve(entry.target);
  });
}, { threshold: .14, rootMargin: '-30px 0px' });

document.querySelectorAll('[data-reveal], [data-reveal-stagger]').forEach(el => observer.observe(el));

function count(el) {
  if (el.dataset.done) return;
  el.dataset.done = 'true';
  const target = Number(el.dataset.target);
  if (reduce) { el.textContent = target.toLocaleString(); return; }
  const start = performance.now();
  const tick = now => {
    const p = Math.min((now - start) / 900, 1);
    el.textContent = Math.round(target * (1 - Math.pow(1 - p, 3))).toLocaleString();
    if (p < 1) requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}

if (!reduce && matchMedia('(pointer:fine)').matches) {
  document.querySelectorAll('[data-tilt]').forEach(card => {
    card.addEventListener('pointermove', e => {
      const r = card.getBoundingClientRect();
      const x = (e.clientX - r.left) / r.width - .5;
      const y = (e.clientY - r.top) / r.height - .5;
      card.style.transform = `perspective(700px) rotateX(${-y * 5}deg) rotateY(${x * 5}deg) translateY(-3px)`;
    });
    card.addEventListener('pointerleave', () => card.style.transform = '');
  });
}

addEventListener('scroll', () => {
  const max = document.documentElement.scrollHeight - innerHeight;
  document.querySelector('.progress').style.transform = `scaleX(${max ? scrollY / max : 0})`;
}, { passive: true });
