// Home, Library, Search screens for mobile

function HomeScreen({ onOpenAlbum, onOpenArtist, onOpenAI }) {
  const featuredAlbums = LIBRARY.albums.slice(0, 4);
  const recentAlbums = LIBRARY.albums.slice(2, 8);
  const artists = LIBRARY.artists.slice(0, 6);
  return (
    <div style={{
      padding: '8px 20px 180px', fontFamily: '"Space Grotesk", system-ui, sans-serif',
      height: '100%', overflowY: 'auto',
    }}>
      {/* Greeting */}
      <div style={{ marginBottom: 18, marginTop: 6 }}>
        <div style={{ fontSize: 11, color: '#5a6a88', fontWeight: 600, letterSpacing: 1.5, textTransform: 'uppercase', marginBottom: 4 }}>Tuesday Evening</div>
        <h1 style={{ margin: 0, fontSize: 30, fontWeight: 500, color: '#1a2540', letterSpacing: -0.8, lineHeight: 1.05 }}>
          Soft landing,<br/><span style={{ fontStyle: 'italic', fontWeight: 400, color: '#5a6a98' }}>welcome back.</span>
        </h1>
      </div>

      {/* AI playlist card — hero */}
      <button onClick={onOpenAI} style={{
        width: '100%', border: 'none', padding: 0, background: 'transparent', cursor: 'pointer', marginBottom: 22,
      }}>
        <Glass intensity="heavy" radius={20} style={{ padding: 18, textAlign: 'left', position: 'relative', overflow: 'hidden' }}>
          <div style={{ position: 'absolute', right: -30, top: -30, width: 160, height: 160, borderRadius: '50%',
            background: 'radial-gradient(circle, #c8b4ff 0%, transparent 70%)', filter: 'blur(10px)', opacity: 0.7 }} />
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 }}>
            <div style={{ width: 26, height: 26, borderRadius: '50%',
              background: 'linear-gradient(135deg, #9bb8ff 0%, #d0a8ff 100%)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              boxShadow: '0 2px 8px rgba(155,184,255,0.5)' }}>
              <Icon name="sparkle" size={14} stroke="#fff" />
            </div>
            <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: 1.5, color: '#6e4ab8', textTransform: 'uppercase' }}>One-Tap Playlist</span>
          </div>
          <div style={{ fontSize: 22, fontWeight: 500, color: '#1a2540', letterSpacing: -0.4, lineHeight: 1.15, marginBottom: 4 }}>
            Describe a mood.<br/>We'll compose the rest.
          </div>
          <div style={{ fontSize: 13, color: '#5a6a88', marginTop: 6 }}>"Rainy Sunday, slow coffee, jazz" →</div>
        </Glass>
      </button>

      {/* Featured */}
      <SectionHead title="Featured" />
      <div style={{ display: 'flex', gap: 12, overflowX: 'auto', margin: '0 -20px', padding: '0 20px 4px', scrollbarWidth: 'none' }}>
        {featuredAlbums.map(a => (
          <button key={a.id} onClick={() => onOpenAlbum(a.id)} style={{
            border: 'none', background: 'transparent', padding: 0, cursor: 'pointer',
            textAlign: 'left', flexShrink: 0, width: 160,
          }}>
            <AlbumArt album={a} size={160} radius={16} showLabel={false} />
            <div style={{ fontSize: 13, fontWeight: 600, color: '#1a2540', marginTop: 8, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{a.title}</div>
            <div style={{ fontSize: 11, color: '#5a6a88' }}>{getArtist(a.artistId).name}</div>
          </button>
        ))}
      </div>

      {/* Artists */}
      <SectionHead title="Artists you love" style={{ marginTop: 22 }} />
      <div style={{ display: 'flex', gap: 14, overflowX: 'auto', margin: '0 -20px', padding: '0 20px 4px', scrollbarWidth: 'none' }}>
        {artists.map(a => (
          <button key={a.id} onClick={() => onOpenArtist(a.id)} style={{
            border: 'none', background: 'transparent', padding: 0, cursor: 'pointer',
            textAlign: 'center', flexShrink: 0, width: 84,
          }}>
            <ArtistAvatar artist={a} size={84} />
            <div style={{ fontSize: 12, fontWeight: 600, color: '#1a2540', marginTop: 6, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{a.name.split(' ')[0]}</div>
          </button>
        ))}
      </div>

      {/* Recently played */}
      <SectionHead title="Recently played" style={{ marginTop: 22 }} />
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
        {recentAlbums.slice(0, 6).map(a => (
          <button key={a.id} onClick={() => onOpenAlbum(a.id)} style={{
            border: 'none', background: 'transparent', padding: 0, cursor: 'pointer', textAlign: 'left',
          }}>
            <Glass intensity="light" radius={14} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: 8 }}>
              <AlbumArt album={a} size={48} radius={8} showLabel={false} />
              <div style={{ minWidth: 0, flex: 1 }}>
                <div style={{ fontSize: 12, fontWeight: 600, color: '#1a2540', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{a.title}</div>
                <div style={{ fontSize: 10, color: '#5a6a88', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{getArtist(a.artistId).name}</div>
              </div>
            </Glass>
          </button>
        ))}
      </div>
    </div>
  );
}

function SectionHead({ title, style = {} }) {
  return (
    <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 10, ...style }}>
      <h2 style={{ margin: 0, fontSize: 16, fontWeight: 600, color: '#1a2540', letterSpacing: -0.2 }}>{title}</h2>
      <button style={{ fontSize: 11, color: '#5a6a88', background: 'transparent', border: 'none', fontWeight: 600, cursor: 'pointer' }}>See all</button>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
function LibraryScreen({ onOpenAlbum, onOpenArtist }) {
  const [tab, setTab] = React.useState('albums');
  const [view, setView] = React.useState('grid');
  const tabs = [
    { id: 'albums', label: 'Albums' }, { id: 'artists', label: 'Artists' },
    { id: 'playlists', label: 'Playlists' }, { id: 'tracks', label: 'Songs' },
  ];
  return (
    <div style={{ padding: '6px 20px 180px', fontFamily: '"Space Grotesk", system-ui, sans-serif', height: '100%', overflowY: 'auto' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-end', marginBottom: 14, marginTop: 4 }}>
        <h1 style={{ margin: 0, fontSize: 32, fontWeight: 500, color: '#1a2540', letterSpacing: -0.8 }}>Library</h1>
        <div style={{ display: 'flex', gap: 4 }}>
          <button onClick={() => setView(view === 'grid' ? 'list' : 'grid')} style={{
            width: 34, height: 34, borderRadius: 10, border: 'none',
            background: 'rgba(255,255,255,0.6)', cursor: 'pointer',
            boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.9), 0 1px 3px rgba(100,130,180,0.1)',
            display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#3a4a6a',
          }}>
            <Icon name={view === 'grid' ? 'list' : 'grid'} size={16} />
          </button>
          <button style={{
            width: 34, height: 34, borderRadius: 10, border: 'none',
            background: 'rgba(255,255,255,0.6)', cursor: 'pointer',
            boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.9), 0 1px 3px rgba(100,130,180,0.1)',
            display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#3a4a6a',
          }}>
            <Icon name="filter" size={16} />
          </button>
        </div>
      </div>

      {/* Tab pills */}
      <div style={{ display: 'flex', gap: 6, marginBottom: 16, overflowX: 'auto', margin: '0 -20px 16px', padding: '0 20px', scrollbarWidth: 'none' }}>
        {tabs.map(t => (
          <button key={t.id} onClick={() => setTab(t.id)} style={{
            padding: '7px 14px', borderRadius: 100, border: 'none',
            fontSize: 13, fontWeight: 600, cursor: 'pointer', flexShrink: 0,
            fontFamily: '"Space Grotesk", system-ui, sans-serif',
            background: tab === t.id
              ? 'linear-gradient(180deg, rgba(255,255,255,0.95) 0%, rgba(230,240,252,0.8) 100%)'
              : 'rgba(255,255,255,0.35)',
            color: tab === t.id ? '#1a2540' : '#55688a',
            boxShadow: tab === t.id
              ? 'inset 0 1px 0 rgba(255,255,255,0.95), 0 2px 8px rgba(100,130,180,0.15)'
              : 'inset 0 1px 0 rgba(255,255,255,0.6)',
          }}>{t.label}</button>
        ))}
      </div>

      {tab === 'albums' && (
        view === 'grid' ? (
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
            {LIBRARY.albums.map(a => (
              <button key={a.id} onClick={() => onOpenAlbum(a.id)} style={{ border: 'none', background: 'transparent', padding: 0, cursor: 'pointer', textAlign: 'left' }}>
                <AlbumArt album={a} size="100%" radius={14} showLabel={false} />
                <div style={{ fontSize: 13, fontWeight: 600, color: '#1a2540', marginTop: 6, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{a.title}</div>
                <div style={{ fontSize: 11, color: '#5a6a88' }}>{getArtist(a.artistId).name} · {a.year}</div>
              </button>
            ))}
          </div>
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
            {LIBRARY.albums.map(a => (
              <button key={a.id} onClick={() => onOpenAlbum(a.id)} style={{
                border: 'none', background: 'transparent', padding: '8px 6px', cursor: 'pointer', textAlign: 'left',
                display: 'flex', alignItems: 'center', gap: 12, borderBottom: '1px solid rgba(200,215,235,0.3)',
              }}>
                <AlbumArt album={a} size={52} radius={8} showLabel={false} />
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 14, fontWeight: 600, color: '#1a2540' }}>{a.title}</div>
                  <div style={{ fontSize: 12, color: '#5a6a88' }}>{getArtist(a.artistId).name} · {a.tracks} tracks</div>
                </div>
                <Icon name="chevronRight" size={16} stroke="#8595b5" />
              </button>
            ))}
          </div>
        )
      )}

      {tab === 'artists' && (
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 12 }}>
          {LIBRARY.artists.map(a => (
            <button key={a.id} onClick={() => onOpenArtist(a.id)} style={{ border: 'none', background: 'transparent', padding: 0, cursor: 'pointer', textAlign: 'center' }}>
              <ArtistAvatar artist={a} size="100%" />
              <div style={{ fontSize: 12, fontWeight: 600, color: '#1a2540', marginTop: 6 }}>{a.name}</div>
              <div style={{ fontSize: 10, color: '#5a6a88' }}>{a.tag}</div>
            </button>
          ))}
        </div>
      )}

      {tab === 'playlists' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          {LIBRARY.playlists.map(p => (
            <Glass key={p.id} intensity="light" radius={14} style={{ padding: 12, display: 'flex', alignItems: 'center', gap: 12 }}>
              <div style={{ width: 56, height: 56, borderRadius: 10,
                background: 'linear-gradient(135deg, #b8d4ff 0%, #d8b8ff 50%, #ffc8e0 100%)',
                boxShadow: 'inset 0 0 0 1px rgba(255,255,255,0.7)',
                display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#fff' }}>
                <Icon name="sparkle" size={22} stroke="#fff" />
              </div>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 14, fontWeight: 600, color: '#1a2540' }}>{p.title}</div>
                <div style={{ fontSize: 11, color: '#5a6a88' }}>{p.tracks} tracks · {p.desc}</div>
              </div>
              <Icon name="more" size={18} stroke="#8595b5" />
            </Glass>
          ))}
        </div>
      )}

      {tab === 'tracks' && (
        <div style={{ display: 'flex', flexDirection: 'column' }}>
          {LIBRARY.tracks.map((t, i) => {
            const alb = getAlbum(t.albumId); const ar = getArtist(t.artistId);
            return (
              <div key={t.id} style={{
                padding: '10px 4px', display: 'flex', alignItems: 'center', gap: 12,
                borderBottom: '1px solid rgba(200,215,235,0.3)',
              }}>
                <AlbumArt album={alb} size={40} radius={6} showLabel={false} />
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 14, fontWeight: 600, color: '#1a2540' }}>{t.title}</div>
                  <div style={{ fontSize: 11, color: '#5a6a88' }}>{ar.name}</div>
                </div>
                <span style={{ fontSize: 11, color: '#8595b5' }}>{fmtTime(t.duration)}</span>
                <Icon name="more" size={16} stroke="#8595b5" />
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
function SearchScreen() {
  const [q, setQ] = React.useState('');
  return (
    <div style={{ padding: '6px 20px 180px', fontFamily: '"Space Grotesk", system-ui, sans-serif', height: '100%', overflowY: 'auto' }}>
      <h1 style={{ margin: '4px 0 14px', fontSize: 32, fontWeight: 500, color: '#1a2540', letterSpacing: -0.8 }}>Search</h1>
      <Glass intensity="light" radius={16} style={{ padding: '10px 14px', display: 'flex', alignItems: 'center', gap: 10, marginBottom: 20 }}>
        <Icon name="search" size={18} stroke="#55688a" />
        <input
          value={q} onChange={e => setQ(e.target.value)}
          placeholder="Artists, albums, songs, moods…"
          style={{
            flex: 1, border: 'none', background: 'transparent', outline: 'none',
            fontSize: 14, color: '#1a2540', fontFamily: '"Space Grotesk", system-ui, sans-serif',
          }}/>
        <Icon name="mic" size={18} stroke="#55688a" />
      </Glass>

      <h2 style={{ margin: '0 0 10px', fontSize: 14, fontWeight: 600, color: '#1a2540' }}>Browse by genre</h2>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
        {LIBRARY.genres.map(g => (
          <div key={g.id} style={{
            height: 84, borderRadius: 14, padding: 14, position: 'relative', overflow: 'hidden',
            background: `linear-gradient(135deg, ${g.color} 0%, rgba(255,255,255,0.4) 100%)`,
            boxShadow: 'inset 0 0 0 1px rgba(255,255,255,0.7), 0 2px 10px rgba(100,130,180,0.12)',
            fontSize: 16, fontWeight: 600, color: '#1a2540',
          }}>
            {g.title}
            <div style={{ position: 'absolute', right: -10, bottom: -10, width: 70, height: 70, borderRadius: '50%',
              background: 'rgba(255,255,255,0.5)', filter: 'blur(2px)' }} />
          </div>
        ))}
      </div>
    </div>
  );
}

Object.assign(window, { HomeScreen, LibraryScreen, SearchScreen });
