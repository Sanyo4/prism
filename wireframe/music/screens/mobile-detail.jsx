// Album detail, Artist detail, Now Playing (full), AI playlist creator

// ─────────────────────────────────────────────────────────────
// Album detail
// ─────────────────────────────────────────────────────────────
function AlbumScreen({ albumId, onBack, onPlayTrack, accent }) {
  const album = getAlbum(albumId);
  const artist = getArtist(album.artistId);
  const tracks = tracksForAlbum(albumId);
  return (
    <div style={{ padding: '0 0 180px', fontFamily: '"Space Grotesk", system-ui, sans-serif', height: '100%', overflowY: 'auto' }}>
      {/* top bar */}
      <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 20px 10px' }}>
        <button onClick={onBack} style={{
          width: 38, height: 38, borderRadius: '50%', border: 'none',
          background: 'rgba(255,255,255,0.7)', cursor: 'pointer',
          boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.95), 0 2px 6px rgba(100,130,180,0.12)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <Icon name="back" size={18} stroke="#2a3754" />
        </button>
        <button style={{
          width: 38, height: 38, borderRadius: '50%', border: 'none',
          background: 'rgba(255,255,255,0.7)', cursor: 'pointer',
          boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.95), 0 2px 6px rgba(100,130,180,0.12)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <Icon name="more" size={18} stroke="#2a3754" />
        </button>
      </div>

      {/* Large art */}
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', padding: '4px 20px 18px' }}>
        <div style={{ filter: 'drop-shadow(0 20px 40px rgba(100,130,180,0.25))' }}>
          <AlbumArt album={album} size={220} radius={20} />
        </div>
        <h1 style={{ margin: '18px 0 2px', fontSize: 24, fontWeight: 500, color: '#1a2540', letterSpacing: -0.5 }}>{album.title}</h1>
        <div style={{ fontSize: 13, color: '#55688a', fontWeight: 500 }}>{artist.name} · {album.year} · {album.tracks} tracks</div>
      </div>

      {/* Play + like row */}
      <div style={{ padding: '0 20px 18px', display: 'flex', gap: 10, alignItems: 'center' }}>
        <ChromeButton primary accent={accent} size="lg" style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6 }}>
          <Icon name="play" size={14} stroke="#fff" />
          <span>Play</span>
        </ChromeButton>
        <ChromeButton size="lg" style={{ padding: '12px 16px', display: 'flex', alignItems: 'center', gap: 6 }}>
          <Icon name="shuffle" size={14} />
        </ChromeButton>
        <ChromeButton size="lg" style={{ padding: '12px 16px' }}>
          <Icon name="heart" size={14} />
        </ChromeButton>
      </div>

      {/* Track list */}
      <div style={{ padding: '0 20px' }}>
        {tracks.map((t, i) => (
          <button key={t.id} onClick={() => onPlayTrack(t.id)} style={{
            width: '100%', border: 'none', background: 'transparent', padding: '10px 4px',
            display: 'flex', alignItems: 'center', gap: 12, cursor: 'pointer', textAlign: 'left',
            borderBottom: '1px solid rgba(200,215,235,0.3)',
          }}>
            <span style={{ width: 24, fontSize: 12, color: '#8595b5', fontVariantNumeric: 'tabular-nums' }}>{(i + 1).toString().padStart(2, '0')}</span>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 14, fontWeight: 600, color: '#1a2540' }}>{t.title}</div>
              <div style={{ fontSize: 11, color: '#5a6a88' }}>{t.plays} plays</div>
            </div>
            <span style={{ fontSize: 11, color: '#8595b5', fontVariantNumeric: 'tabular-nums' }}>{fmtTime(t.duration)}</span>
            <Icon name="more" size={16} stroke="#8595b5" />
          </button>
        ))}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Artist detail
// ─────────────────────────────────────────────────────────────
function ArtistScreen({ artistId, onBack, onOpenAlbum, accent }) {
  const artist = getArtist(artistId);
  const albums = albumsForArtist(artistId);
  const popular = LIBRARY.tracks.filter(t => t.artistId === artistId).slice(0, 5);
  return (
    <div style={{ padding: '0 0 180px', fontFamily: '"Space Grotesk", system-ui, sans-serif', height: '100%', overflowY: 'auto' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 20px 10px' }}>
        <button onClick={onBack} style={{
          width: 38, height: 38, borderRadius: '50%', border: 'none',
          background: 'rgba(255,255,255,0.7)', cursor: 'pointer',
          boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.95), 0 2px 6px rgba(100,130,180,0.12)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <Icon name="back" size={18} stroke="#2a3754" />
        </button>
        <button style={{
          width: 38, height: 38, borderRadius: '50%', border: 'none',
          background: 'rgba(255,255,255,0.7)', cursor: 'pointer',
          boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.95), 0 2px 6px rgba(100,130,180,0.12)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <Icon name="more" size={18} stroke="#2a3754" />
        </button>
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', padding: '10px 20px 18px' }}>
        <div style={{ filter: 'drop-shadow(0 16px 30px rgba(100,130,180,0.2))' }}>
          <ArtistAvatar artist={artist} size={160} />
        </div>
        <h1 style={{ margin: '16px 0 4px', fontSize: 28, fontWeight: 500, color: '#1a2540', letterSpacing: -0.6 }}>{artist.name}</h1>
        <div style={{ fontSize: 12, color: '#55688a', fontWeight: 500 }}>{artist.monthly} monthly listeners · {artist.tag}</div>
      </div>

      <div style={{ padding: '0 20px 20px', display: 'flex', gap: 10 }}>
        <ChromeButton primary accent={accent} size="md" style={{ flex: 1 }}>Follow</ChromeButton>
        <ChromeButton size="md" style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6 }}>
          <Icon name="shuffle" size={13} />Shuffle
        </ChromeButton>
      </div>

      <div style={{ padding: '0 20px' }}>
        <h2 style={{ margin: '0 0 10px', fontSize: 15, fontWeight: 600, color: '#1a2540' }}>Popular</h2>
        {popular.map((t, i) => {
          const alb = getAlbum(t.albumId);
          return (
            <div key={t.id} style={{ padding: '8px 0', display: 'flex', alignItems: 'center', gap: 12, borderBottom: '1px solid rgba(200,215,235,0.3)' }}>
              <span style={{ width: 18, fontSize: 12, color: '#8595b5' }}>{i + 1}</span>
              <AlbumArt album={alb} size={40} radius={6} showLabel={false} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 13, fontWeight: 600, color: '#1a2540' }}>{t.title}</div>
                <div style={{ fontSize: 11, color: '#5a6a88' }}>{t.plays} plays</div>
              </div>
            </div>
          );
        })}
      </div>

      <div style={{ padding: '18px 20px 0' }}>
        <h2 style={{ margin: '0 0 10px', fontSize: 15, fontWeight: 600, color: '#1a2540' }}>Albums</h2>
        <div style={{ display: 'flex', gap: 12, overflowX: 'auto', margin: '0 -20px', padding: '0 20px 4px', scrollbarWidth: 'none' }}>
          {albums.map(a => (
            <button key={a.id} onClick={() => onOpenAlbum(a.id)} style={{ border: 'none', background: 'transparent', padding: 0, cursor: 'pointer', textAlign: 'left', flexShrink: 0, width: 140 }}>
              <AlbumArt album={a} size={140} radius={14} showLabel={false} />
              <div style={{ fontSize: 12, fontWeight: 600, color: '#1a2540', marginTop: 6 }}>{a.title}</div>
              <div style={{ fontSize: 10, color: '#5a6a88' }}>{a.year}</div>
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Now Playing — full-screen glass player
// ─────────────────────────────────────────────────────────────
function NowPlayingScreen({ state, onClose, onTogglePlay, onNext, onPrev, onSeek, accent }) {
  const track = getTrack(state.trackId);
  const album = getAlbum(track.albumId);
  const artist = getArtist(track.artistId);
  const [liked, setLiked] = React.useState(true);
  return (
    <div style={{
      position: 'absolute', inset: 0, zIndex: 30,
      fontFamily: '"Space Grotesk", system-ui, sans-serif',
      display: 'flex', flexDirection: 'column',
    }}>
      <AuroraBg variant="player" accent={accent}>
        <div style={{ display: 'flex', flexDirection: 'column', height: '100%', padding: '4px 24px 24px' }}>
          {/* header */}
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 0 4px' }}>
            <button onClick={onClose} style={{
              width: 38, height: 38, borderRadius: '50%', border: 'none',
              background: 'rgba(255,255,255,0.55)', cursor: 'pointer',
              boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.9), 0 2px 6px rgba(100,130,180,0.1)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
            }}>
              <Icon name="chevronDown" size={20} stroke="#2a3754" />
            </button>
            <div style={{ textAlign: 'center' }}>
              <div style={{ fontSize: 10, color: '#55688a', fontWeight: 600, letterSpacing: 1.5, textTransform: 'uppercase' }}>Playing from album</div>
              <div style={{ fontSize: 13, color: '#1a2540', fontWeight: 600 }}>{album.title}</div>
            </div>
            <button style={{
              width: 38, height: 38, borderRadius: '50%', border: 'none',
              background: 'rgba(255,255,255,0.55)', cursor: 'pointer',
              boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.9), 0 2px 6px rgba(100,130,180,0.1)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
            }}>
              <Icon name="more" size={18} stroke="#2a3754" />
            </button>
          </div>

          {/* album art */}
          <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '20px 0' }}>
            <div style={{
              filter: 'drop-shadow(0 30px 60px rgba(100,130,180,0.3))',
              transform: state.isPlaying ? 'scale(1)' : 'scale(0.92)',
              transition: 'transform 0.4s cubic-bezier(0.2, 0.8, 0.2, 1)',
            }}>
              <AlbumArt album={album} size={300} radius={24} />
            </div>
          </div>

          {/* title + heart */}
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
            <div style={{ minWidth: 0, flex: 1 }}>
              <div style={{ fontSize: 24, fontWeight: 500, color: '#1a2540', letterSpacing: -0.5, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{track.title}</div>
              <div style={{ fontSize: 14, color: '#55688a', fontWeight: 500 }}>{artist.name}</div>
            </div>
            <button onClick={() => setLiked(!liked)} style={{
              width: 44, height: 44, borderRadius: '50%', border: 'none',
              background: liked ? `linear-gradient(180deg, ${accent}22, ${accent}11)` : 'rgba(255,255,255,0.5)',
              cursor: 'pointer',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
            }}>
              <Icon name={liked ? 'heartf' : 'heart'} size={20} stroke={liked ? accent : '#55688a'} />
            </button>
          </div>

          {/* scrub */}
          <AeroSlider value={state.progress} max={track.duration} onChange={onSeek} accent={accent} height={5} />
          <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 11, color: '#55688a', fontVariantNumeric: 'tabular-nums', marginTop: 2, marginBottom: 10 }}>
            <span>{fmtTime(state.progress)}</span>
            <span>-{fmtTime(track.duration - state.progress)}</span>
          </div>

          {/* transport */}
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '4px 4px 14px' }}>
            <button style={iconBtnStyle}><Icon name="shuffle" size={20} stroke="#3a4a6a" /></button>
            <button onClick={onPrev} style={iconBtnStyle}><Icon name="prev" size={28} stroke="#1a2540" /></button>
            <button onClick={onTogglePlay} style={{
              width: 72, height: 72, borderRadius: '50%', border: 'none',
              background: `radial-gradient(circle at 32% 28%, rgba(255,255,255,0.6) 0%, rgba(255,255,255,0) 45%), linear-gradient(180deg, ${accent} 0%, ${accent}dd 50%, ${accent}bb 100%)`,
              boxShadow: `inset 0 2px 0 rgba(255,255,255,0.5), inset 0 -2px 0 rgba(0,0,0,0.08), 0 8px 20px ${accent}66, 0 2px 6px rgba(40,60,100,0.2)`,
              cursor: 'pointer', color: '#fff',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
            }}>
              <Icon name={state.isPlaying ? 'pause' : 'play'} size={26} stroke="#fff" />
            </button>
            <button onClick={onNext} style={iconBtnStyle}><Icon name="next" size={28} stroke="#1a2540" /></button>
            <button style={iconBtnStyle}><Icon name="repeat" size={20} stroke="#3a4a6a" /></button>
          </div>

          {/* bottom utility */}
          <Glass intensity="light" radius={16} style={{
            padding: '10px 14px', display: 'flex', alignItems: 'center', gap: 10,
          }}>
            <Icon name="volume" size={16} stroke="#55688a" />
            <div style={{ flex: 1 }}>
              <AeroSlider value={65} max={100} onChange={() => {}} accent={accent} height={4} />
            </div>
            <button style={{ border: 'none', background: 'transparent', cursor: 'pointer', display: 'flex', gap: 4, alignItems: 'center', color: '#55688a', fontSize: 11, fontWeight: 600 }}>
              <Icon name="cast" size={16} stroke="#55688a" />
            </button>
            <button style={{ border: 'none', background: 'transparent', cursor: 'pointer', display: 'flex', gap: 4, alignItems: 'center', color: '#55688a', fontSize: 11, fontWeight: 600 }}>
              <Icon name="queue" size={16} stroke="#55688a" />
            </button>
          </Glass>
        </div>
      </AuroraBg>
    </div>
  );
}

const iconBtnStyle = {
  width: 50, height: 50, borderRadius: '50%', border: 'none',
  background: 'transparent', cursor: 'pointer',
  display: 'flex', alignItems: 'center', justifyContent: 'center',
};

// ─────────────────────────────────────────────────────────────
// AI one-shot playlist creator
// ─────────────────────────────────────────────────────────────
function AIPlaylistScreen({ onClose, accent }) {
  const [prompt, setPrompt] = React.useState('');
  const [stage, setStage] = React.useState('input'); // input | generating | result
  const [result, setResult] = React.useState(null);
  const suggestions = [
    'Rainy Sunday, slow coffee, jazz',
    'Late night drive through Shibuya',
    'Saturday morning, pancakes, sunshine',
    'Writing a thesis, no lyrics',
    '1998 shopping mall, y2k pop',
  ];

  const generate = async (p) => {
    setPrompt(p);
    setStage('generating');
    try {
      const text = await window.claude.complete(
        `You are a music curator. Given the mood "${p}", propose a playlist of 6 real-sounding (but fictional) tracks in this JSON format ONLY, no commentary:\n{"title":"<playlist title, 2-4 words, evocative>","subtitle":"<mood summary, 6-10 words>","tracks":[{"title":"<song>","artist":"<artist>"}, ...]}\nMake the tracks feel cohesive and match the mood. Invent new artists and songs.`
      );
      const match = text.match(/\{[\s\S]*\}/);
      const data = match ? JSON.parse(match[0]) : null;
      if (data && data.tracks) {
        setResult(data);
        setStage('result');
      } else {
        throw new Error('bad');
      }
    } catch (e) {
      // fallback
      setResult({
        title: 'Golden Hour Glass',
        subtitle: 'Warm, unhurried, softly optimistic',
        tracks: [
          { title: 'Ceramic Rain', artist: 'Ondine Park' },
          { title: 'Chrome Pastoral', artist: 'Marisol Kaminari' },
          { title: 'Soft Machine', artist: 'Quiet Rooms' },
          { title: 'Low Tide FM', artist: 'The Kelp Orchestra' },
          { title: 'Paperweight', artist: 'Juneberry' },
          { title: 'Pearl Interface', artist: 'Hiro Nishimura' },
        ],
      });
      setStage('result');
    }
  };

  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 30, fontFamily: '"Space Grotesk", system-ui, sans-serif' }}>
      <AuroraBg variant="ai" accent={accent}>
        <div style={{ padding: '4px 20px 24px', height: '100%', display: 'flex', flexDirection: 'column' }}>
          {/* header */}
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 0' }}>
            <button onClick={onClose} style={{
              width: 38, height: 38, borderRadius: '50%', border: 'none',
              background: 'rgba(255,255,255,0.55)', cursor: 'pointer',
              boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.9)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
            }}>
              <Icon name="close" size={18} stroke="#2a3754" />
            </button>
            <div style={{ fontSize: 10, color: '#6e4ab8', fontWeight: 700, letterSpacing: 1.5, textTransform: 'uppercase' }}>✦ One-tap Playlist</div>
            <div style={{ width: 38 }} />
          </div>

          {stage === 'input' && (
            <>
              <div style={{ marginTop: 40, marginBottom: 24 }}>
                <div style={{ fontSize: 34, fontWeight: 500, color: '#1a2540', letterSpacing: -0.8, lineHeight: 1.1, marginBottom: 10 }}>
                  Describe the<br/>
                  <span style={{ fontStyle: 'italic', background: 'linear-gradient(120deg, #6e4ab8, #b866c8)', WebkitBackgroundClip: 'text', color: 'transparent' }}>mood, moment, or memory.</span>
                </div>
                <div style={{ fontSize: 13, color: '#55688a' }}>One prompt. One playlist. No saving, no account clutter — just what you need right now.</div>
              </div>

              <Glass intensity="heavy" radius={20} style={{ padding: 14, marginBottom: 18 }}>
                <textarea
                  value={prompt} onChange={e => setPrompt(e.target.value)}
                  placeholder="e.g. 'Rainy Sunday, slow coffee, jazz'…"
                  style={{
                    width: '100%', minHeight: 88, border: 'none', background: 'transparent', outline: 'none',
                    fontSize: 15, color: '#1a2540', fontFamily: '"Space Grotesk", system-ui, sans-serif',
                    resize: 'none',
                  }}
                />
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: 8 }}>
                  <div style={{ fontSize: 11, color: '#55688a' }}>{prompt.length}/240</div>
                  <ChromeButton primary accent={accent} size="md" onClick={() => prompt && generate(prompt)} style={{ display: 'flex', alignItems: 'center', gap: 6, opacity: prompt ? 1 : 0.5 }}>
                    <Icon name="sparkle" size={13} stroke="#fff" />
                    <span>Compose</span>
                  </ChromeButton>
                </div>
              </Glass>

              <div style={{ fontSize: 11, color: '#55688a', fontWeight: 600, letterSpacing: 1, textTransform: 'uppercase', marginBottom: 10 }}>Try one of these</div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                {suggestions.map(s => (
                  <button key={s} onClick={() => generate(s)} style={{
                    padding: '12px 14px', borderRadius: 12, border: 'none',
                    background: 'rgba(255,255,255,0.45)',
                    textAlign: 'left', cursor: 'pointer', fontSize: 13, color: '#2a3754', fontWeight: 500,
                    fontFamily: '"Space Grotesk", system-ui, sans-serif',
                    boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.8), 0 1px 3px rgba(100,130,180,0.08)',
                    display: 'flex', justifyContent: 'space-between', alignItems: 'center',
                  }}>
                    <span>"{s}"</span>
                    <Icon name="chevronRight" size={14} stroke="#8595b5" />
                  </button>
                ))}
              </div>
            </>
          )}

          {stage === 'generating' && (
            <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 18 }}>
              <div style={{ position: 'relative', width: 140, height: 140 }}>
                <div style={{ position: 'absolute', inset: 0, borderRadius: '50%',
                  background: 'conic-gradient(from 0deg, #9bb8ff, #d0a8ff, #ffb8d4, #9bb8ff)',
                  animation: 'spin 3s linear infinite', filter: 'blur(2px)' }} />
                <div style={{ position: 'absolute', inset: 10, borderRadius: '50%',
                  background: 'radial-gradient(circle at 30% 30%, rgba(255,255,255,0.85), rgba(255,255,255,0.5))',
                  boxShadow: 'inset 0 0 0 1px rgba(255,255,255,0.8)',
                  display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                  <Icon name="sparkle" size={40} stroke="#6e4ab8" />
                </div>
              </div>
              <div style={{ textAlign: 'center' }}>
                <div style={{ fontSize: 18, fontWeight: 500, color: '#1a2540' }}>Composing your playlist…</div>
                <div style={{ fontSize: 12, color: '#55688a', marginTop: 4, fontStyle: 'italic' }}>"{prompt}"</div>
              </div>
            </div>
          )}

          {stage === 'result' && result && (
            <div style={{ flex: 1, overflowY: 'auto', marginTop: 16 }}>
              <Glass intensity="heavy" radius={20} style={{ padding: 18, marginBottom: 16 }}>
                <div style={{ fontSize: 10, fontWeight: 700, letterSpacing: 1.5, color: '#6e4ab8', textTransform: 'uppercase', marginBottom: 6 }}>Generated for you</div>
                <div style={{ fontSize: 24, fontWeight: 500, color: '#1a2540', letterSpacing: -0.4, lineHeight: 1.1 }}>{result.title}</div>
                <div style={{ fontSize: 12, color: '#55688a', marginTop: 4 }}>{result.subtitle}</div>
                <div style={{ display: 'flex', gap: 8, marginTop: 14 }}>
                  <ChromeButton primary accent={accent} size="md" style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6 }}>
                    <Icon name="play" size={12} stroke="#fff" /> Play all
                  </ChromeButton>
                  <ChromeButton size="md" onClick={() => setStage('input')}>Regenerate</ChromeButton>
                </div>
              </Glass>

              <div style={{ display: 'flex', flexDirection: 'column' }}>
                {result.tracks.map((t, i) => (
                  <div key={i} style={{
                    padding: '10px 4px', display: 'flex', alignItems: 'center', gap: 12,
                    borderBottom: '1px solid rgba(200,215,235,0.3)',
                  }}>
                    <span style={{ width: 20, fontSize: 12, color: '#8595b5' }}>{i + 1}</span>
                    <div style={{ width: 40, height: 40, borderRadius: 8,
                      background: `linear-gradient(135deg, hsl(${i * 55}, 70%, 88%), hsl(${i * 55 + 40}, 65%, 82%))`,
                      boxShadow: 'inset 0 0 0 1px rgba(255,255,255,0.7)' }} />
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ fontSize: 14, fontWeight: 600, color: '#1a2540' }}>{t.title}</div>
                      <div style={{ fontSize: 11, color: '#5a6a88' }}>{t.artist}</div>
                    </div>
                    <Icon name="plus" size={16} stroke="#8595b5" />
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>
      </AuroraBg>
    </div>
  );
}

Object.assign(window, { AlbumScreen, ArtistScreen, NowPlayingScreen, AIPlaylistScreen });
