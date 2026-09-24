const c=supabase.createClient(SUPABASE_URL,SUPABASE_KEY),token=new URLSearchParams(location.search).get('token'),m=document.getElementById('message'),box=document.getElementById('share'),accepted=document.getElementById('accepted');
let contactName='',accepting=false,redirectTimer;
const target=`contatto-condiviso.html${location.search}`;
document.getElementById('login-link').href=`login.html?return_to=${encodeURIComponent(target)}`;
document.getElementById('signup-link').href=`registrati.html?return_to=${encodeURIComponent(target)}`;
function error(e){const x=(e?.message||'').toLowerCase();if(x.includes('verified'))return 'Per usare questa condivisione devi verificare l’indirizzo email.';if(x.includes('recipient mismatch'))return 'Questa condivisione è destinata a un altro account.';return 'Questa condivisione non è disponibile.';}
async function load(){if(!token){m.textContent='Condivisione non valida.';return;}const{data:{session}}=await c.auth.getSession();if(!session){m.textContent='';document.getElementById('anonymous').hidden=false;return;}const{data,error:e}=await c.rpc('get_contact_share_for_recipient',{p_token:token});if(e){m.textContent=error(e);return;}contactName=[data.first_name,data.last_name].filter(Boolean).join(' ');document.getElementById('name').textContent=contactName;document.getElementById('email').textContent=data.email;box.hidden=false;m.textContent='';}
document.getElementById('accept').onclick=async()=>{if(accepting)return;accepting=true;const b=document.getElementById('accept');b.disabled=true;const{error:e}=await c.rpc('accept_contact_share',{p_token:token});if(e){accepting=false;b.disabled=false;m.textContent=error(e);return;}box.hidden=true;m.textContent=`${contactName||'Il contatto'} è stata aggiunta ai tuoi Contatti.`;accepted.hidden=false;redirectTimer=setTimeout(()=>location.assign('contatti.html'),1800);};
document.getElementById('contacts-link').onclick=()=>clearTimeout(redirectTimer);
load();
