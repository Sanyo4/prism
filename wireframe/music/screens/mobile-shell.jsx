// Mobile screens — Pixel 9 Pro Fold outer (412w) and inner (720w) displays
// Glassmorphic Y2K Aero aesthetic.

// ─────────────────────────────────────────────────────────────
// Aurora backdrop — the thing that makes everything below glassy
// ─────────────────────────────────────────────────────────────
function AuroraBg({ variant = 'home', accent = '#6ba8ff', children, style = {} }) {
  const variants = {
    home: {
      bg: 'linear-gradient(160deg, #eaf2fc 0%, #f4ecfa 50%, #fdf0f5 100%)',
      blobs: [
        { left: '-10%', top: '-15%', size: 420, color: '#c8ddff', opacity: 0.7 },
        { right: '-15%', top: '10%',  size: 380, color: '#ffd6ed', opacity: 0.55 },
        { left: '20%',  bottom: '-20%', size: 480, color: '#d0f0e4', opacity: 0.5 },
      ],
    },
    album: {
      bg: 'linear-gradient(165deg, #e4eefb 0%, #f8e8f4 60%, #fff4e8 100%)',
      blobs: [
        { left: '10%', top: '-20%', size: 460, color: '#b8e0ff', opacity: 0.7 },
        { right: '-20%', top: '30%', size: 520, color: '#ffc8e8', opacity: 0.55 },
      ],
    },
    player: {
      bg: 'linear-gradient(170deg, #dce8fa 0%, #f0ddf0 50%, #ffe4da 100%)',
      blobs: [
        { left: '-20%', top: '-10%', size: 520, color: '#b4d8ff', opacity: 0.8 },
        { right: '-10%', top: '40%', size: 480, color: '#ffc4de', opacity: 0.6 },
        { left: '30%', bottom: '-25%', size: 420, color: '#ffe0b8', opacity: 0.5 },
      ],
    },
    library: {
      bg: 'linear-gradient(155deg, #e8f0fa 0%, #efe8f8 100%)',
      blobs: [
        { right: '-15%', top: '-10%', size: 400, color: '#c8dfff', opacity: 0.6 },
        { left: '-20%', bottom: '-15%', size: 440, color: '#e0d4f4', opacity: 0.55 },
      ],
    },
    ai: {
      bg: 'linear-gradient(165deg, #dce8ff 0%, #e8deff 50%, #ffe0f0 100%)',
      blobs: [
        { left: '-10%', top: '-10%', size: 500, color: '#b8c8ff', opacity: 0.75 },
        { right: '-20%', top: '20%', size: 440, color: '#d8b8ff', opacity: 0.65 },
        { left: '20%', bottom: '-20%', size: 460, color: '#ffc4e0', opacity: 0.55 },
      ],
    },
  };
  const v = variants[variant] || variants.home;
  return (
    <div style={{
      position: 'absolute', inset: 0, overflow: 'hidden',
      background: v.bg,
      ...style,
    }}>
      {v.blobs.map((b, i) => (
        <div key={i} style={{
          position: 'absolute',
          left: b.left, right: b.right, top: b.top, bottom: b.bottom,
          width: b.size, height: b.size, borderRadius: '50%',
          background: `radial-gradient(circle, ${b.color} 0%, transparent 70%)`,
          opacity: b.opacity,
          filter: 'blur(40px)',
        }} />
      ))}
      {/* grain */}
      <div style={{
        position: 'absolute', inset: 0,
        backgroundImage: `url("data:image/svg+xml,%3Csvg viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.85' numOctaves='2'/%3E%3C/filter%3E%3Crect width='200' height='200' filter='url(%23n)' opacity='0.5'/%3E%3C/svg%3E")`,
        opacity: 0.12, mixBlendMode: 'overlay', pointerEvents: 'none',
      }} />
      <div style={{ position: 'relative', zIndex: 1, height: '100%' }}>{children}</div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Phone status bar (custom, matches Y2K theme — white text if dark)
// ─────────────────────────────────────────────────────────────
function PhoneStatusBar({ dark = false }) {
  const c = dark ? '#fff' : '#2a3754';
  return (
    <div style={{
      height: 40, display: 'flex', alignItems: 'center',
      justifyContent: 'space-between', padding: '0 22px',
      position: 'relative', flexShrink: 0,
      fontFamily: '"Space Grotesk", system-ui, sans-serif',
    }}>
      <span style={{ fontSize: 14, fontWeight: 600, color: c, letterSpacing: 0.2 }}>10:08</span>
      <div style={{
        position: 'absolute', left: '50%', top: 10, transform: 'translateX(-50%)',
        width: 22, height: 22, borderRadius: '50%', background: '#1a1a1a',
      }} />
      <div style={{ display: 'flex', alignItems: 'center', gap: 5, color: c }}>
        <svg width="14" height="14" viewBox="0 0 14 14" fill={c}><path d="M7 11.5L.7 5.2a8.7 8.7 0 0112.6 0L7 11.5z"/></svg>
        <span style={{ fontSize: 11, fontWeight: 600 }}>5G</span>
        <svg width="22" height="11" viewBox="0 0 22 11"><rect x="0.5" y="0.5" width="18" height="10" rx="2.5" fill="none" stroke={c} strokeOpacity="0.6"/><rect x="2" y="2" width="13" height="7" rx="1" fill={c}/><rect x="19.5" y="3.5" width="1.5" height="4" rx="0.5" fill={c} opacity="0.6"/></svg>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Mini player — floating glass pill
// ─────────────────────────────────────────────────────────────
function MiniPlayer({ state, onExpand, onTogglePlay, onNext, accent }) {
  const track = getTrack(state.trackId);
  const album = getAlbum(track.albumId);
  const artist = getArtist(track.artistId);
  return (
    <div
      onClick={onExpand}
      style={{
        position: 'absolute', left: 10, right: 10, bottom: 90,
        cursor: 'pointer',
      }}
    >
      <Glass intensity="heavy" radius={22} style={{
        padding: '8px 10px 10px', display: 'flex', alignItems: 'center', gap: 10,
      }}>
        <AlbumArt album={album} size={44} radius={10} showLabel={false} />
        <div style={{ flex: 1, minWidth: 0, fontFamily: '"Space Grotesk", system-ui, sans-serif' }}>
          <div style={{ fontSize: 14, fontWeight: 600, color: '#1a2540', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{track.title}</div>
          <div style={{ fontSize: 11, color: '#5a6a88', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{artist.name}</div>
        </div>
        <button onClick={(e) => { e.stopPropagation(); onTogglePlay(); }} style={{
          width: 36, height: 36, borderRadius: '50%', border: 'none',
          background: `linear-gradient(180deg, ${accent} 0%, ${accent}dd 100%)`,
          boxShadow: `inset 0 1px 0 rgba(255,255,255,0.5), 0 2px 8px ${accent}66`,
          display: 'flex', alignItems: 'center', justifyContent: 'center', cursor: 'pointer',
          color: '#fff',
        }}>
          <Icon name={state.isPlaying ? 'pause' : 'play'} size={16} />
        </button>
        <button onClick={(e) => { e.stopPropagation(); onNext(); }} style={{
          width: 32, height: 32, border: 'none', background: 'transparent', color: '#3a4a6a', cursor: 'pointer',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <Icon name="next" size={18} />
        </button>
        {/* thin progress strip */}
        <div style={{
          position: 'absolute', left: 12, right: 12, bottom: 3, height: 2, borderRadius: 2,
          background: 'rgba(120,140,180,0.2)', overflow: 'hidden',
        }}>
          <div style={{
            width: `${(state.progress / getTrack(state.trackId).duration) * 100}%`, height: '100%',
            background: `linear-gradient(90deg, ${accent}, ${accent}aa)`,
          }}/>
        </div>
      </Glass>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Bottom nav — glass tab bar
// ─────────────────────────────────────────────────────────────
function BottomNav({ current, onNav, accent }) {
  const items = [
    { id: 'home', icon: 'home', label: 'Home' },
    { id: 'search', icon: 'search', label: 'Search' },
    { id: 'library', icon: 'library', label: 'Library' },
    { id: 'ai', icon: 'sparkle', label: 'Create' },
  ];
  return (
    <div style={{ position: 'absolute', left: 10, right: 10, bottom: 10, zIndex: 20 }}>
      <Glass intensity="heavy" radius={28} style={{
        display: 'flex', padding: '6px', gap: 2,
      }}>
        {items.map(it => {
          const active = current === it.id;
          return (
            <button key={it.id} onClick={() => onNav(it.id)} style={{
              flex: 1, border: 'none', background: active
                ? `linear-gradient(180deg, rgba(255,255,255,0.9), rgba(255,255,255,0.5))`
                : 'transparent',
              borderRadius: 22, padding: '10px 4px',
              display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 3,
              color: active ? accent : '#55688a',
              cursor: 'pointer', fontFamily: '"Space Grotesk", system-ui, sans-serif',
              boxShadow: active ? `inset 0 1px 0 rgba(255,255,255,0.95), 0 2px 6px ${accent}33` : 'none',
            }}>
              <Icon name={it.icon} size={20} />
              <span style={{ fontSize: 10, fontWeight: 600 }}>{it.label}</span>
            </button>
          );
        })}
      </Glass>
    </div>
  );
}

Object.assign(window, { AuroraBg, PhoneStatusBar, MiniPlayer, BottomNav });
