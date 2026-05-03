// Linux desktop (GTK-ish) window with glass panels
// Sidebar (library) + main content + player bar

function DesktopApp({ state, onTogglePlay, onNext, onPrev, onSeek, accent }) {
  const [route, setRoute] = React.useState({ type: 'home' });
  const track = getTrack(state.trackId);
  const album = getAlbum(track.albumId);
  const artist = getArtist(track.artistId);

  return (
    <div style={{
      width: 1200, height: 760, borderRadius: 14, overflow: 'hidden',
      boxShadow: '0 30px 80px rgba(30,40,60,0.35), 0 2px 12px rgba(30,40,60,0.2)',
      display: 'flex', flexDirection: 'column',
      position: 'relative',
      fontFamily: '"Space Grotesk", system-ui, sans-serif',
    }}>
      {/* aurora bg */}
      <div style={{ position: 'absolute', inset: 0, zIndex: 0 }}>
        <AuroraBg variant="home" accent={accent} />
      </div>

      {/* GNOME-style titlebar */}
      <div style={{
        position: 'relative', zIndex: 2,
        height: 44, background: 'rgba(255,255,255,0.6)',
        backdropFilter: 'blur(30px) saturate(180%)',
        WebkitBackdropFilter: 'blur(30px) saturate(180%)',
        borderBottom: '1px solid rgba(180,200,220,0.4)',
        display: 'flex', alignItems: 'center', padding: '0 14px', gap: 12,
      }}>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
          <div style={{ display: 'flex', gap: 6 }}>
            <button style={nav38}><Icon name="back" size={14} stroke="#3a4a6a" /></button>
            <button style={nav38}><Icon name="chevronRight" size={14} stroke="#3a4a6a" /></button>
          </div>
        </div>
        <div style={{ flex: 1, display: 'flex', justifyContent: 'center' }}>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 8,
            background: 'rgba(255,255,255,0.6)',
            padding: '6px 14px', borderRadius: 100,
            width: 360,
            boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.9), inset 0 0 0 1px rgba(180,200,220,0.4)',
          }}>
            <Icon name="search" size={14} stroke="#55688a" />
            <span style={{ fontSize: 13, color: '#8595b5' }}>Search Prism</span>
          </div>
        </div>
        <div style={{ display: 'flex', gap: 6 }}>
          <button style={nav28}><Icon name="minimize" size={12} stroke="#3a4a6a" /></button>
          <button style={nav28}><Icon name="window" size={12} stroke="#3a4a6a" /></button>
          <button style={{ ...nav28, background: '#e06060', color: '#fff' }}><Icon name="close" size={12} stroke="#fff" /></button>
        </div>
      </div>

      {/* Body */}
      <div style={{ flex: 1, display: 'flex', position: 'relative', zIndex: 1, minHeight: 0 }}>
        {/* Sidebar */}
        <div style={{
          width: 240, padding: 14, overflowY: 'auto',
          background: 'linear-gradient(180deg, rgba(255,255,255,0.45) 0%, rgba(255,255,255,0.25) 100%)',
          backdropFilter: 'blur(30px) saturate(160%)',
          WebkitBackdropFilter: 'blur(30px) saturate(160%)',
          borderRight: '1px solid rgba(200,215,235,0.4)',
        }}>
          <div style={{ fontSize: 10, fontWeight: 700, letterSpacing: 1.5, color: '#55688a', textTransform: 'uppercase', padding: '4px 10px 8px' }}>Prism</div>
          <SideItem icon="home" label="Home" active={route.type === 'home'} onClick={() => setRoute({ type: 'home' })} />
          <SideItem icon="search" label="Search" onClick={() => setRoute({ type: 'search' })} active={route.type === 'search'} />
          <SideItem icon="library" label="Library" onClick={() => setRoute({ type: 'library' })} active={route.type === 'library'} />
          <SideItem icon="sparkle" label="Compose ✦" onClick={() => setRoute({ type: 'ai' })} active={route.type === 'ai'} accent={accent} />

          <div style={{ fontSize: 10, fontWeight: 700, letterSpacing: 1.5, color: '#55688a', textTransform: 'uppercase', padding: '18px 10px 8px' }}>Playlists</div>
          {LIBRARY.playlists.map(p => (
            <div key={p.id} style={{
              padding: '7px 10px', fontSize: 13, color: '#2a3754', borderRadius: 8, cursor: 'pointer',
              display: 'flex', alignItems: 'center', gap: 8,
            }}>
              <div style={{ width: 6, height: 6, borderRadius: '50%', background: accent }} />
              {p.title}
            </div>
          ))}
          <div style={{ fontSize: 10, fontWeight: 700, letterSpacing: 1.5, color: '#55688a', textTransform: 'uppercase', padding: '18px 10px 8px' }}>Recent</div>
          {LIBRARY.albums.slice(0, 4).map(a => (
            <div key={a.id} onClick={() => setRoute({ type: 'album', id: a.id })} style={{
              padding: '6px 8px', display: 'flex', alignItems: 'center', gap: 10, cursor: 'pointer', borderRadius: 8,
            }}>
              <AlbumArt album={a} size={32} radius={5} showLabel={false} />
              <div style={{ minWidth: 0, flex: 1 }}>
                <div style={{ fontSize: 12, fontWeight: 600, color: '#1a2540', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{a.title}</div>
                <div style={{ fontSize: 10, color: '#5a6a88', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{getArtist(a.artistId).name}</div>
              </div>
            </div>
          ))}
        </div>

        {/* Main */}
        <div style={{ flex: 1, overflowY: 'auto', padding: '22px 28px 28px' }}>
          {route.type === 'home' && <DesktopHome onOpenAlbum={(id) => setRoute({ type: 'album', id })} onOpenArtist={(id) => setRoute({ type: 'artist', id })} accent={accent} />}
          {route.type === 'album' && <DesktopAlbum albumId={route.id} accent={accent} />}
          {route.type === 'artist' && <DesktopArtist artistId={route.id} onOpenAlbum={(id) => setRoute({ type: 'album', id })} accent={accent} />}
          {route.type === 'library' && <DesktopLibrary onOpenAlbum={(id) => setRoute({ type: 'album', id })} />}
          {route.type === 'search' && <DesktopSearch />}
          {route.type === 'ai' && <DesktopAI accent={accent} />}
        </div>
      </div>

      {/* Player bar */}
      <div style={{
        position: 'relative', zIndex: 2,
        height: 88, padding: '0 18px',
        background: 'rgba(255,255,255,0.6)',
        backdropFilter: 'blur(40px) saturate(180%)',
        WebkitBackdropFilter: 'blur(40px) saturate(180%)',
        borderTop: '1px solid rgba(200,215,235,0.5)',
        display: 'grid', gridTemplateColumns: '1fr 1.4fr 1fr', alignItems: 'center', gap: 18,
      }}>
        {/* Left: now playing */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, minWidth: 0 }}>
          <AlbumArt album={album} size={56} radius={10} showLabel={false} />
          <div style={{ minWidth: 0 }}>
            <div style={{ fontSize: 13, fontWeight: 600, color: '#1a2540', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{track.title}</div>
            <div style={{ fontSize: 11, color: '#5a6a88', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{artist.name} · {album.title}</div>
          </div>
          <button style={{ ...nav28, marginLeft: 4 }}><Icon name="heartf" size={12} stroke={accent} /></button>
        </div>

        {/* Center: transport + scrub */}
        <div>
          <div style={{ display: 'flex', justifyContent: 'center', alignItems: 'center', gap: 12, marginBottom: 4 }}>
            <button style={nav32}><Icon name="shuffle" size={14} stroke="#55688a" /></button>
            <button onClick={onPrev} style={nav32}><Icon name="prev" size={16} stroke="#2a3754" /></button>
            <button onClick={onTogglePlay} style={{
              width: 38, height: 38, borderRadius: '50%', border: 'none', cursor: 'pointer',
              background: `linear-gradient(180deg, ${accent}, ${accent}dd)`,
              boxShadow: `inset 0 1px 0 rgba(255,255,255,0.5), 0 2px 8px ${accent}66`,
              display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#fff',
            }}>
              <Icon name={state.isPlaying ? 'pause' : 'play'} size={14} stroke="#fff" />
            </button>
            <button onClick={onNext} style={nav32}><Icon name="next" size={16} stroke="#2a3754" /></button>
            <button style={nav32}><Icon name="repeat" size={14} stroke="#55688a" /></button>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <span style={{ fontSize: 10, color: '#55688a', fontVariantNumeric: 'tabular-nums', minWidth: 32, textAlign: 'right' }}>{fmtTime(state.progress)}</span>
            <div style={{ flex: 1 }}>
              <AeroSlider value={state.progress} max={track.duration} onChange={onSeek} accent={accent} height={4} />
            </div>
            <span style={{ fontSize: 10, color: '#55688a', fontVariantNumeric: 'tabular-nums', minWidth: 32 }}>{fmtTime(track.duration)}</span>
          </div>
        </div>

        {/* Right: volume + queue */}
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'flex-end', gap: 10 }}>
          <button style={nav32}><Icon name="queue" size={14} stroke="#55688a" /></button>
          <button style={nav32}><Icon name="cast" size={14} stroke="#55688a" /></button>
          <Icon name="volume" size={14} stroke="#55688a" />
          <div style={{ width: 100 }}>
            <AeroSlider value={65} max={100} onChange={() => {}} accent={accent} height={3} />
          </div>
        </div>
      </div>
    </div>
  );
}

const nav38 = {
  width: 32, height: 32, borderRadius: 10, border: 'none',
  background: 'rgba(255,255,255,0.55)', cursor: 'pointer',
  boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.9), inset 0 0 0 1px rgba(200,215,235,0.5)',
  display: 'flex', alignItems: 'center', justifyContent: 'center',
};
const nav32 = {
  width: 30, height: 30, borderRadius: '50%', border: 'none',
  background: 'transparent', cursor: 'pointer',
  display: 'flex', alignItems: 'center', justifyContent: 'center',
};
const nav28 = {
  width: 24, height: 24, borderRadius: '50%', border: 'none',
  background: 'rgba(0,0,0,0.06)', cursor: 'pointer',
  display: 'flex', alignItems: 'center', justifyContent: 'center',
};

function SideItem({ icon, label, active, onClick, accent = '#6ba8ff' }) {
  return (
    <div onClick={onClick} style={{
      padding: '8px 10px', display: 'flex', alignItems: 'center', gap: 10,
      borderRadius: 10, cursor: 'pointer',
      background: active ? 'linear-gradient(180deg, rgba(255,255,255,0.9), rgba(255,255,255,0.5))' : 'transparent',
      boxShadow: active ? 'inset 0 1px 0 rgba(255,255,255,0.9), 0 2px 6px rgba(100,130,180,0.1)' : 'none',
      color: active ? accent : '#2a3754',
      fontSize: 13, fontWeight: active ? 600 : 500,
    }}>
      <Icon name={icon} size={16} stroke={active ? accent : '#55688a'} />
      {label}
    </div>
  );
}

// ── content views ────────────────────────────────────────────
function DesktopHome({ onOpenAlbum, onOpenArtist, accent }) {
  return (
    <div>
      <div style={{ marginBottom: 24 }}>
        <div style={{ fontSize: 10, color: '#55688a', fontWeight: 700, letterSpacing: 1.5, textTransform: 'uppercase', marginBottom: 6 }}>Tuesday Evening</div>
        <h1 style={{ margin: 0, fontSize: 36, fontWeight: 500, color: '#1a2540', letterSpacing: -0.8 }}>
          Good evening. <span style={{ fontStyle: 'italic', color: '#5a6a98' }}>Here's what's new.</span>
        </h1>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14, marginBottom: 24 }}>
        {LIBRARY.albums.slice(0, 4).map(a => (
          <button key={a.id} onClick={() => onOpenAlbum(a.id)} style={{
            border: 'none', padding: 0, background: 'transparent', cursor: 'pointer', textAlign: 'left',
          }}>
            <Glass intensity="light" radius={14} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: 8, paddingRight: 16 }}>
              <AlbumArt album={a} size={64} radius={8} showLabel={false} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 14, fontWeight: 600, color: '#1a2540' }}>{a.title}</div>
                <div style={{ fontSize: 11, color: '#5a6a88' }}>{getArtist(a.artistId).name}</div>
              </div>
              <button style={{
                width: 36, height: 36, borderRadius: '50%', border: 'none', cursor: 'pointer',
                background: `linear-gradient(180deg, ${accent}, ${accent}dd)`,
                boxShadow: `0 2px 8px ${accent}66`,
                display: 'flex', alignItems: 'center', justifyContent: 'center',
              }}>
                <Icon name="play" size={12} stroke="#fff" />
              </button>
            </Glass>
          </button>
        ))}
      </div>

      <h2 style={{ margin: '0 0 12px', fontSize: 18, fontWeight: 600, color: '#1a2540' }}>Featured albums</h2>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 14, marginBottom: 24 }}>
        {LIBRARY.albums.slice(0, 4).map(a => (
          <button key={a.id} onClick={() => onOpenAlbum(a.id)} style={{ border: 'none', background: 'transparent', padding: 0, cursor: 'pointer', textAlign: 'left' }}>
            <AlbumArt album={a} size="100%" radius={12} showLabel={false} />
            <div style={{ fontSize: 13, fontWeight: 600, color: '#1a2540', marginTop: 8 }}>{a.title}</div>
            <div style={{ fontSize: 11, color: '#5a6a88' }}>{getArtist(a.artistId).name}</div>
          </button>
        ))}
      </div>

      <h2 style={{ margin: '0 0 12px', fontSize: 18, fontWeight: 600, color: '#1a2540' }}>Artists</h2>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(6, 1fr)', gap: 14 }}>
        {LIBRARY.artists.slice(0, 6).map(a => (
          <button key={a.id} onClick={() => onOpenArtist(a.id)} style={{ border: 'none', background: 'transparent', padding: 0, cursor: 'pointer', textAlign: 'center' }}>
            <ArtistAvatar artist={a} size="100%" />
            <div style={{ fontSize: 12, fontWeight: 600, color: '#1a2540', marginTop: 6 }}>{a.name}</div>
            <div style={{ fontSize: 10, color: '#5a6a88' }}>{a.tag}</div>
          </button>
        ))}
      </div>
    </div>
  );
}

function DesktopAlbum({ albumId, accent }) {
  const album = getAlbum(albumId);
  const artist = getArtist(album.artistId);
  const tracks = tracksForAlbum(albumId);
  return (
    <div>
      <div style={{ display: 'flex', gap: 26, alignItems: 'flex-end', marginBottom: 26 }}>
        <div style={{ filter: 'drop-shadow(0 20px 40px rgba(100,130,180,0.25))' }}>
          <AlbumArt album={album} size={220} radius={16} />
        </div>
        <div style={{ paddingBottom: 10 }}>
          <div style={{ fontSize: 11, fontWeight: 700, color: '#55688a', letterSpacing: 1.5, textTransform: 'uppercase' }}>Album</div>
          <h1 style={{ margin: '6px 0 10px', fontSize: 44, fontWeight: 500, color: '#1a2540', letterSpacing: -1, lineHeight: 1 }}>{album.title}</h1>
          <div style={{ fontSize: 14, color: '#2a3754', fontWeight: 500 }}>{artist.name} · {album.year} · {tracks.length} songs</div>
          <div style={{ display: 'flex', gap: 10, marginTop: 18 }}>
            <ChromeButton primary accent={accent} size="md" style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
              <Icon name="play" size={12} stroke="#fff" /> Play
            </ChromeButton>
            <ChromeButton size="md"><Icon name="shuffle" size={12} /></ChromeButton>
            <ChromeButton size="md"><Icon name="heart" size={12} /></ChromeButton>
            <ChromeButton size="md"><Icon name="more" size={12} /></ChromeButton>
          </div>
        </div>
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: '30px 1fr 100px 60px', gap: 12, padding: '8px 10px', borderBottom: '1px solid rgba(200,215,235,0.4)', fontSize: 10, color: '#55688a', fontWeight: 700, letterSpacing: 1, textTransform: 'uppercase' }}>
        <span>#</span><span>Title</span><span>Plays</span><span style={{ textAlign: 'right' }}>Time</span>
      </div>
      {tracks.map((t, i) => (
        <div key={t.id} style={{ display: 'grid', gridTemplateColumns: '30px 1fr 100px 60px', gap: 12, padding: '10px', fontSize: 13, alignItems: 'center', color: '#2a3754', borderRadius: 8 }}>
          <span style={{ color: '#8595b5', fontVariantNumeric: 'tabular-nums' }}>{i + 1}</span>
          <div>
            <div style={{ fontWeight: 600, color: '#1a2540' }}>{t.title}</div>
            <div style={{ fontSize: 11, color: '#5a6a88' }}>{artist.name}</div>
          </div>
          <span style={{ color: '#5a6a88', fontVariantNumeric: 'tabular-nums' }}>{t.plays}</span>
          <span style={{ color: '#8595b5', textAlign: 'right', fontVariantNumeric: 'tabular-nums' }}>{fmtTime(t.duration)}</span>
        </div>
      ))}
    </div>
  );
}

function DesktopArtist({ artistId, onOpenAlbum, accent }) {
  const artist = getArtist(artistId);
  const albums = albumsForArtist(artistId);
  const popular = LIBRARY.tracks.filter(t => t.artistId === artistId);
  return (
    <div>
      <div style={{ display: 'flex', gap: 26, alignItems: 'center', marginBottom: 26 }}>
        <ArtistAvatar artist={artist} size={180} />
        <div>
          <div style={{ fontSize: 11, fontWeight: 700, color: '#55688a', letterSpacing: 1.5, textTransform: 'uppercase' }}>Artist</div>
          <h1 style={{ margin: '6px 0 8px', fontSize: 52, fontWeight: 500, color: '#1a2540', letterSpacing: -1, lineHeight: 1 }}>{artist.name}</h1>
          <div style={{ fontSize: 14, color: '#2a3754' }}>{artist.tag} · {artist.monthly} monthly listeners</div>
          <div style={{ display: 'flex', gap: 10, marginTop: 16 }}>
            <ChromeButton primary accent={accent} size="md">Follow</ChromeButton>
            <ChromeButton size="md">Shuffle play</ChromeButton>
          </div>
        </div>
      </div>
      <h2 style={{ margin: '0 0 10px', fontSize: 16, fontWeight: 600, color: '#1a2540' }}>Popular</h2>
      <div style={{ marginBottom: 24 }}>
        {popular.slice(0, 5).map((t, i) => (
          <div key={t.id} style={{ padding: '8px 10px', display: 'flex', alignItems: 'center', gap: 12 }}>
            <span style={{ width: 18, color: '#8595b5', fontSize: 12 }}>{i + 1}</span>
            <AlbumArt album={getAlbum(t.albumId)} size={36} radius={6} showLabel={false} />
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 13, fontWeight: 600, color: '#1a2540' }}>{t.title}</div>
            </div>
            <span style={{ fontSize: 11, color: '#5a6a88' }}>{t.plays}</span>
            <span style={{ fontSize: 11, color: '#8595b5' }}>{fmtTime(t.duration)}</span>
          </div>
        ))}
      </div>
      <h2 style={{ margin: '0 0 12px', fontSize: 16, fontWeight: 600, color: '#1a2540' }}>Discography</h2>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 14 }}>
        {albums.map(a => (
          <button key={a.id} onClick={() => onOpenAlbum(a.id)} style={{ border: 'none', background: 'transparent', padding: 0, cursor: 'pointer', textAlign: 'left' }}>
            <AlbumArt album={a} size="100%" radius={10} showLabel={false} />
            <div style={{ fontSize: 13, fontWeight: 600, color: '#1a2540', marginTop: 6 }}>{a.title}</div>
            <div style={{ fontSize: 10, color: '#5a6a88' }}>{a.year}</div>
          </button>
        ))}
      </div>
    </div>
  );
}

function DesktopLibrary({ onOpenAlbum }) {
  return (
    <div>
      <h1 style={{ margin: '0 0 18px', fontSize: 36, fontWeight: 500, color: '#1a2540', letterSpacing: -0.8 }}>Your library</h1>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(5, 1fr)', gap: 14 }}>
        {LIBRARY.albums.map(a => (
          <button key={a.id} onClick={() => onOpenAlbum(a.id)} style={{ border: 'none', background: 'transparent', padding: 0, cursor: 'pointer', textAlign: 'left' }}>
            <AlbumArt album={a} size="100%" radius={10} showLabel={false} />
            <div style={{ fontSize: 13, fontWeight: 600, color: '#1a2540', marginTop: 6 }}>{a.title}</div>
            <div style={{ fontSize: 10, color: '#5a6a88' }}>{getArtist(a.artistId).name}</div>
          </button>
        ))}
      </div>
    </div>
  );
}

function DesktopSearch() {
  return (
    <div>
      <h1 style={{ margin: '0 0 18px', fontSize: 36, fontWeight: 500, color: '#1a2540', letterSpacing: -0.8 }}>Search</h1>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12 }}>
        {LIBRARY.genres.map(g => (
          <div key={g.id} style={{
            height: 120, borderRadius: 14, padding: 18, overflow: 'hidden', position: 'relative',
            background: `linear-gradient(135deg, ${g.color}, rgba(255,255,255,0.5))`,
            boxShadow: 'inset 0 0 0 1px rgba(255,255,255,0.7), 0 2px 12px rgba(100,130,180,0.1)',
            fontSize: 22, fontWeight: 600, color: '#1a2540',
          }}>{g.title}</div>
        ))}
      </div>
    </div>
  );
}

function DesktopAI({ accent }) {
  const [prompt, setPrompt] = React.useState('');
  return (
    <div style={{ maxWidth: 680, margin: '40px auto' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8 }}>
        <div style={{ width: 30, height: 30, borderRadius: '50%',
          background: 'linear-gradient(135deg, #9bb8ff, #d0a8ff)',
          display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <Icon name="sparkle" size={16} stroke="#fff" />
        </div>
        <div style={{ fontSize: 11, fontWeight: 700, letterSpacing: 1.5, color: '#6e4ab8', textTransform: 'uppercase' }}>One-tap playlist</div>
      </div>
      <h1 style={{ margin: '0 0 10px', fontSize: 38, fontWeight: 500, color: '#1a2540', letterSpacing: -0.8, lineHeight: 1.1 }}>
        Describe your moment. <span style={{ fontStyle: 'italic', background: 'linear-gradient(120deg, #6e4ab8, #b866c8)', WebkitBackgroundClip: 'text', color: 'transparent' }}>We'll compose it.</span>
      </h1>
      <Glass intensity="heavy" radius={18} style={{ padding: 16, marginTop: 20 }}>
        <textarea
          value={prompt} onChange={e => setPrompt(e.target.value)}
          placeholder="e.g. 'Late night drive, soft electronic, no words'…"
          style={{
            width: '100%', minHeight: 100, border: 'none', background: 'transparent', outline: 'none',
            fontSize: 16, color: '#1a2540', fontFamily: '"Space Grotesk", system-ui, sans-serif', resize: 'none',
          }}/>
        <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: 8 }}>
          <ChromeButton primary accent={accent} size="md" style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <Icon name="sparkle" size={12} stroke="#fff" /> Compose playlist
          </ChromeButton>
        </div>
      </Glass>
    </div>
  );
}

Object.assign(window, { DesktopApp });
