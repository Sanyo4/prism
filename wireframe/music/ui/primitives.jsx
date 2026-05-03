// Shared UI primitives — glass surfaces, album art placeholders, icons, sliders.
// All original. Y2K Aero-inspired: frosted glass, liquid chrome, soft blooms.

// ─────────────────────────────────────────────────────────────
// Album art placeholder — generative per album ID
// Makes a soft abstract gradient bloom specific to each album.
// ─────────────────────────────────────────────────────────────
function AlbumArt({ album, size = 80, radius = 14, showLabel = true }) {
  const responsive = size === '100%';
  const sizeStyle = responsive
    ? { width: '100%', aspectRatio: '1 / 1' }
    : { width: size, height: size };
  if (!album) {
    return <div style={{ ...sizeStyle, borderRadius: radius, background: '#dfe7ef' }} />;
  }
  const { color1, color2, color3, title, id } = album;
  // simple hash for offset variety
  const h = id.charCodeAt(id.length - 1) * 7 % 100;
  return (
    <div style={{
      ...sizeStyle, borderRadius: radius,
      position: 'relative', overflow: 'hidden',
      boxShadow: 'inset 0 0 0 1px rgba(255,255,255,0.5), 0 2px 14px rgba(120,140,180,0.18)',
      flexShrink: 0,
      background: `
        radial-gradient(circle at ${20 + h % 40}% ${30 + h % 30}%, ${color1} 0%, transparent 55%),
        radial-gradient(circle at ${70 - h % 30}% ${70 - h % 40}%, ${color2} 0%, transparent 50%),
        radial-gradient(circle at ${50}% ${20}%, ${color3} 0%, transparent 45%),
        linear-gradient(135deg, #f0f4f9 0%, #e4ecf5 100%)
      `,
    }}>
      {/* gloss sweep */}
      <div style={{
        position: 'absolute', inset: 0,
        background: 'linear-gradient(155deg, rgba(255,255,255,0.55) 0%, rgba(255,255,255,0) 42%, rgba(255,255,255,0) 70%, rgba(255,255,255,0.12) 100%)',
        pointerEvents: 'none',
      }} />
      {/* chrome rim */}
      <div style={{
        position: 'absolute', inset: 0, borderRadius: radius,
        boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.85), inset 0 -1px 0 rgba(180,195,215,0.3)',
        pointerEvents: 'none',
      }} />
      {showLabel && size >= 120 && (
        <div style={{
          position: 'absolute', left: 12, bottom: 12, right: 12,
          fontFamily: '"Space Grotesk", system-ui, sans-serif',
          fontSize: 11, fontWeight: 500, letterSpacing: 0.6, textTransform: 'uppercase',
          color: 'rgba(40,50,70,0.55)',
          mixBlendMode: 'multiply',
        }}>
          ♪ {title}
        </div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Artist portrait — circle, abstract per artist
// ─────────────────────────────────────────────────────────────
function ArtistAvatar({ artist, size = 56 }) {
  const responsive = size === '100%';
  const sizeStyle = responsive
    ? { width: '100%', aspectRatio: '1 / 1' }
    : { width: size, height: size };
  if (!artist) return <div style={{ ...sizeStyle, borderRadius: '50%', background: '#dfe7ef' }} />;
  const h = artist.id.charCodeAt(1) * 37 % 360;
  return (
    <div style={{
      ...sizeStyle, borderRadius: '50%',
      position: 'relative', overflow: 'hidden', flexShrink: 0,
      background: `
        radial-gradient(circle at 30% 30%, hsl(${h}, 60%, 88%) 0%, transparent 60%),
        radial-gradient(circle at 75% 70%, hsl(${(h+60)%360}, 55%, 85%) 0%, transparent 55%),
        linear-gradient(135deg, #f4f8fc 0%, #e4edf6 100%)
      `,
      boxShadow: 'inset 0 0 0 1px rgba(255,255,255,0.7), 0 2px 8px rgba(100,120,160,0.12)',
    }}>
      <div style={{
        position: 'absolute', inset: 0,
        background: 'linear-gradient(155deg, rgba(255,255,255,0.6) 0%, rgba(255,255,255,0) 50%)',
      }} />
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Icons — thin line, 24px grid
// ─────────────────────────────────────────────────────────────
const Icon = ({ name, size = 22, stroke = 'currentColor', fill = 'none', strokeWidth = 1.6 }) => {
  const common = { width: size, height: size, viewBox: '0 0 24 24', fill, stroke, strokeWidth, strokeLinecap: 'round', strokeLinejoin: 'round' };
  switch (name) {
    case 'play':    return <svg {...common}><path d="M7 4.5v15l13-7.5-13-7.5z" fill={stroke} stroke={stroke}/></svg>;
    case 'pause':   return <svg {...common}><rect x="6" y="4.5" width="4" height="15" rx="1" fill={stroke}/><rect x="14" y="4.5" width="4" height="15" rx="1" fill={stroke}/></svg>;
    case 'prev':    return <svg {...common}><path d="M6 4.5v15M19 4.5l-13 7.5 13 7.5v-15z" fill={stroke} stroke={stroke}/></svg>;
    case 'next':    return <svg {...common}><path d="M18 4.5v15M5 4.5l13 7.5-13 7.5v-15z" fill={stroke} stroke={stroke}/></svg>;
    case 'shuffle': return <svg {...common}><path d="M3 6h4l10 12h4M3 18h4l4-4.8M17 6h4l-4.5 5.4"/><path d="M17 3l4 3-4 3M17 15l4 3-4 3"/></svg>;
    case 'repeat':  return <svg {...common}><path d="M17 1l4 4-4 4M3 11V9a4 4 0 014-4h14M7 23l-4-4 4-4M21 13v2a4 4 0 01-4 4H3"/></svg>;
    case 'heart':   return <svg {...common}><path d="M20.8 4.6a5.5 5.5 0 00-7.8 0L12 5.6l-1-1a5.5 5.5 0 00-7.8 7.8l1 1L12 21l7.8-7.6 1-1a5.5 5.5 0 000-7.8z"/></svg>;
    case 'heartf':  return <svg {...common}><path d="M20.8 4.6a5.5 5.5 0 00-7.8 0L12 5.6l-1-1a5.5 5.5 0 00-7.8 7.8l1 1L12 21l7.8-7.6 1-1a5.5 5.5 0 000-7.8z" fill={stroke}/></svg>;
    case 'home':    return <svg {...common}><path d="M3 10l9-7 9 7v10a2 2 0 01-2 2h-4v-6h-6v6H5a2 2 0 01-2-2V10z"/></svg>;
    case 'search':  return <svg {...common}><circle cx="11" cy="11" r="7"/><path d="M20 20l-4-4"/></svg>;
    case 'library': return <svg {...common}><path d="M4 3v18M10 3v18M16 7l4 14"/></svg>;
    case 'sparkle': return <svg {...common}><path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8L12 3zM19 3l.9 2.1L22 6l-2.1.9L19 9l-.9-2.1L16 6l2.1-.9L19 3zM5 17l.7 1.6L7 19.3l-1.3.7L5 21.5l-.7-1.5L3 19.3l1.3-.7L5 17z" fill={stroke} stroke="none"/></svg>;
    case 'queue':   return <svg {...common}><path d="M3 6h13M3 12h13M3 18h9M17 15l5 3-5 3v-6z" fill={stroke}/></svg>;
    case 'more':    return <svg {...common}><circle cx="5" cy="12" r="1.5" fill={stroke}/><circle cx="12" cy="12" r="1.5" fill={stroke}/><circle cx="19" cy="12" r="1.5" fill={stroke}/></svg>;
    case 'chevronDown': return <svg {...common}><path d="M6 9l6 6 6-6"/></svg>;
    case 'chevronRight': return <svg {...common}><path d="M9 6l6 6-6 6"/></svg>;
    case 'back':    return <svg {...common}><path d="M19 12H5M12 5l-7 7 7 7"/></svg>;
    case 'close':   return <svg {...common}><path d="M6 6l12 12M18 6L6 18"/></svg>;
    case 'send':    return <svg {...common}><path d="M3 12L22 3l-4 19-5-7-10-3z"/></svg>;
    case 'mic':     return <svg {...common}><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0014 0M12 18v3"/></svg>;
    case 'volume':  return <svg {...common}><path d="M4 9h4l5-4v14l-5-4H4V9z"/><path d="M17 8a5 5 0 010 8M20 5a9 9 0 010 14"/></svg>;
    case 'cast':    return <svg {...common}><path d="M3 17a4 4 0 014 4M3 13a8 8 0 018 8M21 21V6a2 2 0 00-2-2H5a2 2 0 00-2 2v3"/></svg>;
    case 'minimize': return <svg {...common}><path d="M6 15l6-6 6 6"/></svg>;
    case 'window':  return <svg {...common}><rect x="3" y="3" width="18" height="18" rx="2"/></svg>;
    case 'dots':    return <svg {...common}><circle cx="12" cy="5" r="1.5" fill={stroke}/><circle cx="12" cy="12" r="1.5" fill={stroke}/><circle cx="12" cy="19" r="1.5" fill={stroke}/></svg>;
    case 'plus':    return <svg {...common}><path d="M12 5v14M5 12h14"/></svg>;
    case 'filter':  return <svg {...common}><path d="M3 5h18l-7 9v5l-4 2v-7L3 5z"/></svg>;
    case 'grid':    return <svg {...common}><rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/></svg>;
    case 'list':    return <svg {...common}><path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/></svg>;
    case 'download': return <svg {...common}><path d="M12 3v13M6 11l6 6 6-6M4 21h16"/></svg>;
    default: return null;
  }
};

// ─────────────────────────────────────────────────────────────
// Glass pane — frosted aero surface
// ─────────────────────────────────────────────────────────────
function Glass({ children, style = {}, intensity = 'med', radius = 24 }) {
  const blur = intensity === 'heavy' ? 40 : intensity === 'light' ? 14 : 24;
  const sat = intensity === 'heavy' ? 180 : 140;
  return (
    <div style={{
      background: 'linear-gradient(160deg, rgba(255,255,255,0.55) 0%, rgba(255,255,255,0.32) 60%, rgba(255,255,255,0.22) 100%)',
      backdropFilter: `blur(${blur}px) saturate(${sat}%)`,
      WebkitBackdropFilter: `blur(${blur}px) saturate(${sat}%)`,
      borderRadius: radius,
      boxShadow: `
        inset 0 1px 0 rgba(255,255,255,0.95),
        inset 0 -1px 0 rgba(255,255,255,0.25),
        inset 0 0 0 1px rgba(255,255,255,0.4),
        0 10px 30px rgba(100,130,180,0.12),
        0 2px 8px rgba(80,100,140,0.08)
      `,
      ...style,
    }}>
      {children}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Aero Slider — glossy track, liquid chrome thumb
// ─────────────────────────────────────────────────────────────
function AeroSlider({ value, max = 100, onChange, accent = '#6ba8ff', height = 6, showTicks = false }) {
  const ref = React.useRef(null);
  const [dragging, setDragging] = React.useState(false);

  const updateFromEvent = React.useCallback((clientX) => {
    const el = ref.current; if (!el) return;
    const r = el.getBoundingClientRect();
    const pct = Math.max(0, Math.min(1, (clientX - r.left) / r.width));
    onChange && onChange(pct * max);
  }, [max, onChange]);

  React.useEffect(() => {
    if (!dragging) return;
    const mv = (e) => updateFromEvent(e.touches ? e.touches[0].clientX : e.clientX);
    const up = () => setDragging(false);
    window.addEventListener('mousemove', mv);
    window.addEventListener('mouseup', up);
    window.addEventListener('touchmove', mv);
    window.addEventListener('touchend', up);
    return () => {
      window.removeEventListener('mousemove', mv);
      window.removeEventListener('mouseup', up);
      window.removeEventListener('touchmove', mv);
      window.removeEventListener('touchend', up);
    };
  }, [dragging, updateFromEvent]);

  const pct = Math.max(0, Math.min(1, value / max));
  return (
    <div
      ref={ref}
      onMouseDown={(e) => { setDragging(true); updateFromEvent(e.clientX); }}
      onTouchStart={(e) => { setDragging(true); updateFromEvent(e.touches[0].clientX); }}
      style={{
        height: height + 14, display: 'flex', alignItems: 'center',
        cursor: 'pointer', position: 'relative', userSelect: 'none', touchAction: 'none',
      }}
    >
      <div style={{
        position: 'absolute', left: 0, right: 0, height,
        borderRadius: height,
        background: 'linear-gradient(180deg, rgba(200,210,225,0.45) 0%, rgba(220,228,240,0.65) 100%)',
        boxShadow: 'inset 0 1px 2px rgba(80,100,140,0.22), inset 0 -1px 0 rgba(255,255,255,0.6)',
        overflow: 'hidden',
      }}>
        <div style={{
          width: `${pct * 100}%`, height: '100%',
          background: `linear-gradient(180deg, ${accent}dd 0%, ${accent} 50%, ${accent}cc 100%)`,
          boxShadow: `inset 0 1px 0 rgba(255,255,255,0.7), 0 0 10px ${accent}66`,
        }} />
      </div>
      <div style={{
        position: 'absolute', left: `calc(${pct * 100}% - 8px)`,
        width: 16, height: 16, borderRadius: '50%',
        background: `radial-gradient(circle at 35% 30%, #fff 0%, #fff 30%, ${accent} 100%)`,
        boxShadow: `0 2px 6px rgba(40,60,100,0.3), inset 0 0 0 1px rgba(255,255,255,0.9), 0 0 14px ${accent}55`,
        transform: dragging ? 'scale(1.2)' : 'scale(1)',
        transition: dragging ? 'none' : 'transform 0.15s ease',
      }} />
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Chrome button (Aero-style)
// ─────────────────────────────────────────────────────────────
function ChromeButton({ children, onClick, primary = false, size = 'md', accent = '#6ba8ff', style = {} }) {
  const pad = size === 'sm' ? '6px 12px' : size === 'lg' ? '12px 24px' : '9px 18px';
  const fs = size === 'sm' ? 12 : size === 'lg' ? 15 : 13;
  return (
    <button
      onClick={onClick}
      style={{
        padding: pad, fontSize: fs, fontWeight: 500,
        fontFamily: '"Space Grotesk", system-ui, sans-serif',
        letterSpacing: 0.2,
        border: 'none', borderRadius: 100,
        color: primary ? '#fff' : '#2a3754',
        cursor: 'pointer',
        background: primary
          ? `linear-gradient(180deg, ${accent} 0%, ${accent}dd 50%, ${accent}cc 100%)`
          : 'linear-gradient(180deg, rgba(255,255,255,0.9) 0%, rgba(255,255,255,0.55) 50%, rgba(240,245,252,0.7) 100%)',
        boxShadow: primary
          ? `inset 0 1px 0 rgba(255,255,255,0.5), inset 0 -1px 0 rgba(0,0,0,0.1), 0 2px 8px ${accent}55`
          : 'inset 0 1px 0 rgba(255,255,255,0.9), inset 0 -1px 0 rgba(160,180,210,0.3), 0 1px 3px rgba(100,130,180,0.12)',
        ...style,
      }}
    >
      {children}
    </button>
  );
}

Object.assign(window, { AlbumArt, ArtistAvatar, Icon, Glass, AeroSlider, ChromeButton });
