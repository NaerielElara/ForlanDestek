(() => {
  let token = '', accounts = [], licenses = [], history = [];
  const $ = id => document.getElementById(id);
  const date = v => v ? new Date(v).toLocaleString('tr-TR') : 'Süresiz';
  const roles = {admin:'Yönetici',technician:'Teknisyen',customer:'Firma'};
  function notice(text,kind='') { $('notice').textContent=text; $('notice').className=`notice ${kind}`; $('notice').hidden=!text; }
  function logout() { token=''; $('admin-panel').hidden=true; $('login-panel').hidden=false; }
  async function api(path,method='GET',body) {
    const r=await fetch(path,{method,cache:'no-store',headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body?{body:JSON.stringify(body)}:{})});
    const data=await r.json();
    if(r.status===401&&path!='/api/auth/login') logout();
    if(!r.ok) throw new Error(typeof data.detail==='string'?data.detail:JSON.stringify(data.detail));
    return data;
  }
  function table(headers,rows) {
    const t=document.createElement('table'),h=t.createTHead().insertRow(),b=t.createTBody();
    headers.forEach(v=>{const c=document.createElement('th');c.textContent=v;h.append(c);});
    rows.forEach(values=>{const row=b.insertRow();values.forEach(v=>{const cell=row.insertCell();if(v instanceof Node)cell.append(v);else cell.textContent=v??'—';});});return t;
  }
  function button(label,fn,danger=false) {
    const b=document.createElement('button');b.type='button';b.className=`secondary table-action${danger?' danger':''}`;b.textContent=label;
    b.onclick=async()=>{b.disabled=true;try{await fn();}catch(e){notice(e.message,'error');}finally{b.disabled=false;}};return b;
  }
  function actions(items) { const c=document.createElement('div');c.className='action-group';items.forEach(i=>c.append(i));return c; }
  async function refresh() {
    [accounts,licenses,history]=await Promise.all([api('/api/admin/accounts'),api('/api/admin/license-codes'),api('/api/admin/audit')]);
    const select=$('customer-select'),prev=select.value;select.replaceChildren(new Option('Yeni firma oluştur',''));
    accounts.filter(a=>a.role==='customer'&&!a.archived&&!a.disabled).forEach(a=>select.append(new Option(a.display_name,String(a.id))));select.value=prev;firmChanged();render();
  }
  function firmChanged(){ $('firm-name-label').hidden=!!$('customer-select').value; }
  async function accountAction(a,action) {
    let confirmation='';
    if(action==='delete') { confirmation=prompt(`${a.display_name} kalıcı silinecek. Müşteriyse ${a.license_count ?? 0} lisans ve ${a.ticket_count ?? 0} destek kaydı da silinir. Teknisyense işler havuza döner; konuşma ve işlem geçmişi korunur. Onaylamak için adını aynen yazın:`, '');if(confirmation===null)return; }
    else if(!confirm(`${a.display_name}: ${action==='archive'?'arşivle ve oturumlarını kapat':'arşivden geri al'}?`))return;
    await api(`/api/admin/accounts/${a.id}/manage`,'POST',{action,confirmation});await refresh();notice('Hesap işlemi tamamlandı.','success');
  }
  async function licenseAction(l,action) {
    const body={action};
    if(action==='renew') {const value=prompt('Kaç gün uzatılsın? Süresiz için boş bırakın.','365');if(value===null)return;if(value!==''){const n=Number(value);if(!Number.isInteger(n)||n<1||n>36500)throw new Error('1–36500 arasında gün sayısı girin.');body.duration_days=n;}}
    else if(action==='delete'){body.confirmation=prompt(`${l.display_name} lisansı kalıcı silinecek. Onay için firma adını yazın:`, '');if(body.confirmation===null)return;}
    else if(!confirm(`${l.display_name}: ${action==='rotate'?'Kod yenilenecek; eski kod ve ona bağlı oturumlar kapanacak.':action==='revoke'?'Lisans iptal edilecek.':action==='archive'?'Lisans arşivlenecek.':'Lisans arşivden çıkarılacak.'}`))return;
    await api(`/api/admin/licenses/${l.id}/manage`,'POST',body);await refresh();notice('Lisans işlemi tamamlandı. Güncel kod listede görünüyor.','success');
  }
  function render() {
    const q=$('search').value.trim().toLocaleLowerCase('tr-TR'),archived=$('show-archived').checked;
    const matches=v=>String(v).toLocaleLowerCase('tr-TR').includes(q);
    $('accounts').replaceChildren(table(['Firma / Kullanıcı','Kullanıcı adı','Rol','Durum','İşlemler'],accounts.filter(a=>(archived||!a.archived)&&matches(a.display_name)).map(a=>[a.display_name,a.role==='customer'?'Lisans koduyla giriş':a.username,roles[a.role],a.archived?'Arşiv':a.disabled?'Devre dışı':'Aktif',actions([
      button(a.disabled?'Etkinleştir':'Devre dışı',async()=>{await api(`/api/admin/accounts/${a.id}/status`,'PATCH',{disabled:!a.disabled});await refresh();}),
      button(a.archived?'Geri al':'Arşivle',()=>accountAction(a,a.archived?'restore':'archive')),
      button('Kalıcı sil',()=>accountAction(a,'delete'),true)
    ])])));
    $('licenses').replaceChildren(table(['Firma','Lisans kodu','Bitiş','Durum','İşlemler'],licenses.filter(l=>(archived||(!l.archived&&!l.firm_archived))&&matches(l.display_name+' '+(l.code||''))).map(l=>{
      const code=document.createElement('div');code.className='license-code';const text=document.createElement('code');text.textContent=l.code||'Henüz kod üretilmedi';code.append(text);
      if(l.code)code.append(button('Kopyala',async()=>{await navigator.clipboard.writeText(l.code);notice('Lisans kodu kopyalandı.','success');}));
      return [l.display_name,code,date(l.expires_at),l.archived?'Arşiv':l.revoked?'İptal':l.expires_at&&new Date(l.expires_at)<=new Date()?'Süresi dolmuş':'Aktif',actions([
        button('Uzat',()=>licenseAction(l,'renew')),button(l.code?'Kodu yenile':'Kod üret',()=>licenseAction(l,'rotate')),
        button('İptal et',()=>licenseAction(l,'revoke')),button(l.archived?'Geri al':'Arşivle',()=>licenseAction(l,l.archived?'restore':'archive')),button('Kalıcı sil',()=>licenseAction(l,'delete'),true)
      ])];
    })));
    $('audit').replaceChildren(table(['Tarih','İşlemi yapan','İşlem','Kayıt','Ayrıntı'],history.map(h=>[date(h.created_at),h.actor_display_name,h.action,`${h.object_type} #${h.object_id}`,JSON.stringify(h.details)])));
  }
  $('login-form').onsubmit=async e=>{e.preventDefault();const form=e.currentTarget,b=form.querySelector('button');b.disabled=true;try{const values=Object.fromEntries(new FormData(form));const r=await api('/api/auth/login','POST',values);if(r.account.role!=='admin')throw new Error('Yönetici hesabı gerekli.');token=r.access_token;$('identity').textContent=r.account.display_name+' · Yönetici';$('admin-panel').hidden=false;$('login-panel').hidden=true;form.reset();await refresh();notice('');}catch(err){logout();notice(err.message,'error');}finally{b.disabled=false;}};
  $('account-form').onsubmit=async e=>{e.preventDefault();const form=e.currentTarget,b=form.querySelector('button');b.disabled=true;try{await api('/api/admin/accounts','POST',Object.fromEntries(new FormData(form)));form.reset();await refresh();notice('Yetkili hesap oluşturuldu.','success');}catch(err){notice(err.message,'error');}finally{b.disabled=false;}};
  $('license-form').onsubmit=async e=>{e.preventDefault();const form=e.currentTarget,b=form.querySelector('button');b.disabled=true;try{const v=Object.fromEntries(new FormData(form));const body={display_name:v.display_name};if(v.account_id)body.account_id=Number(v.account_id);if(v.duration_days)body.duration_days=Number(v.duration_days);await api('/api/admin/firm-licenses','POST',body);form.reset();await refresh();notice('Lisans üretildi. Kodu aşağıdaki listeden kopyalayabilirsiniz.','success');}catch(err){notice(err.message,'error');}finally{b.disabled=false;}};
  $('logout').onclick=()=>{logout();notice('Oturum kapatıldı.');};$('refresh').onclick=()=>refresh().catch(e=>notice(e.message,'error'));
  $('search').oninput=render;$('show-archived').onchange=render;$('customer-select').onchange=firmChanged;
})();
