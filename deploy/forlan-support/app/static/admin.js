(() => {
  let token = "", accounts = [], licenses = [], history = [], currentAccountId = null;
  let selectedLicense = null, currentDeviceLicense = null, passwordAccount = null, confirmationResolver = null, noticeTimer = null;
  const $ = id => document.getElementById(id);
  const roleNames = {admin:"Yönetici",technician:"Teknisyen",customer:"Firma"};
  const viewNames = {dashboard:"Genel bakış",licenses:"Lisanslar",accounts:"Firmalar ve hesaplar",audit:"İşlem geçmişi"};

  function showNotice(message,kind) {
    const box=$("notice"); clearTimeout(noticeTimer); box.textContent=message||"";
    box.className="toast"+(kind?" "+kind:""); box.hidden=!message;
    if(message) noticeTimer=setTimeout(()=>{box.hidden=true;},kind==="error"?9000:6000);
  }
  function closeDialogs() { document.querySelectorAll("dialog[open]").forEach(d=>d.close()); confirmationResolver=null; }
  function logout() {
    token=""; currentAccountId=null; selectedLicense=null; currentDeviceLicense=null;
    accounts=[]; licenses=[]; history=[]; closeDialogs(); $("app-shell").hidden=true; $("login-screen").hidden=false;
  }
  function apiError(data,status) {
    const detail=data&&data.detail;
    if(typeof detail==="string") return detail;
    if(Array.isArray(detail)) return detail.map(x=>x&&x.msg?x.msg:JSON.stringify(x)).join(" · ");
    if(detail&&typeof detail==="object") return JSON.stringify(detail);
    return "İstek tamamlanamadı ("+status+").";
  }
  async function api(path,method,body) {
    const options={method:method||"GET",cache:"no-store",headers:{"Content-Type":"application/json",...(token?{Authorization:"Bearer "+token}:{})}};
    if(body!==undefined) options.body=JSON.stringify(body);
    const response=await fetch(path,options); let data={};
    try { data=await response.json(); } catch (_) {}
    if(response.status===401&&path!=="/api/auth/login") logout();
    if(!response.ok) throw new Error(apiError(data,response.status));
    return data;
  }
  function dateTime(value,withTime) {
    if(!value) return "—";
    const date=new Date(value); if(Number.isNaN(date.getTime())) return "—";
    return date.toLocaleString("tr-TR",withTime===false?{dateStyle:"medium"}:{dateStyle:"medium",timeStyle:"short"});
  }
  function daysUntil(value) {
    if(!value) return null; const date=new Date(value);
    return Number.isNaN(date.getTime())?null:Math.ceil((date.getTime()-Date.now())/86400000);
  }
  function licenseStatus(license) {
    if(license.archived||license.firm_archived) return "archived";
    if(license.revoked) return "revoked";
    const firm=accounts.find(a=>a.id===license.account_id);
    if(firm&&firm.disabled) return "disabled";
    if(license.expires_at) { const expiry=new Date(license.expires_at).getTime(); const days=daysUntil(license.expires_at); if(!Number.isNaN(expiry)&&expiry<=Date.now())return "expired"; if(days!==null&&days<=14)return "expiring"; }
    return "active";
  }
  const statusNames={active:"Geçerli",expiring:"Yakında dolacak",expired:"Süresi dolmuş",revoked:"İptal edilmiş",archived:"Arşivlenmiş",disabled:"Firma devre dışı"};
  function el(tag,className,text) {
    const result=document.createElement(tag); if(className)result.className=className;
    if(text!==undefined&&text!==null)result.textContent=text; return result;
  }
  function pill(text,className) { return el("span",className,text); }
  function emptyState(title,message) { const box=el("div","empty-state"); box.append(el("strong","",title),document.createTextNode(message||"")); return box; }
  function table(headers,rows) {
    const result=el("table","data-table"),head=result.createTHead().insertRow(),body=result.createTBody();
    headers.forEach(label=>head.append(el("th","",label)));
    rows.forEach(values=>{const row=body.insertRow();values.forEach(value=>{const cell=row.insertCell();if(value instanceof Node)cell.append(value);else cell.textContent=value===undefined||value===null?"—":String(value);});});
    return result;
  }
  function button(label,className,handler,disabled) {
    const result=el("button",className||"secondary-button",label); result.type="button"; result.disabled=!!disabled;
    result.addEventListener("click",async()=>{result.disabled=true;try{await handler();}catch(error){showNotice(error.message||"İşlem tamamlanamadı.","error");}finally{result.disabled=!!disabled;}});
    return result;
  }
  function askConfirmation(options) {
    $("confirm-title").textContent=options.title||"Devam edilsin mi?";
    $("confirm-message").textContent=options.message||"";
    $("confirm-accept").textContent=options.acceptLabel||"Onayla";
    $("confirm-accept").className=options.danger===false?"primary":"danger-button";
    $("confirm-word-wrap").hidden=!options.phrase;
    $("confirm-word-label").textContent=options.phraseLabel||"Onay metni";
    $("confirm-word").value=""; $("confirm-word").placeholder=options.phrase||"";
    $("confirm-error").hidden=true; $("confirm-error").textContent="";
    return new Promise(resolve=>{confirmationResolver=resolve;$("confirm-dialog").showModal();if(options.phrase)$("confirm-word").focus();});
  }
  function resolveConfirmation(answer) {
    if(!confirmationResolver)return; const resolve=confirmationResolver; confirmationResolver=null;
    if($("confirm-dialog").open)$("confirm-dialog").close(); resolve(answer);
  }
  function planPills(license) {
    const box=el("div","plan-stack");
    if(license.license_kind==="trial")box.append(pill("Deneme","plan-pill trial"));
    box.append(pill(license.support_enabled?"Kullanım + destek":"Yalnız kullanım","plan-pill "+(license.support_enabled?"support":"usage-only")));
    return box;
  }
  function companyCell(name,detail) {
    const box=el("div","company-cell"); box.append(el("strong","",name||"Adsız firma"),el("small","",detail||"")); return box;
  }
  function statusPill(status) { return pill(statusNames[status]||status,"status-pill "+status); }
  async function copyCode(code) {
    if(!code)throw new Error("Bu lisans için görüntülenebilir bir kod bulunmuyor.");
    if(!navigator.clipboard||!navigator.clipboard.writeText)throw new Error("Tarayıcı panoya kopyalamaya izin vermedi.");
    await navigator.clipboard.writeText(code); showNotice("Lisans kodu panoya kopyalandı.","success");
  }
  function copyButton(code) { return button("Kopyala","copy-button",()=>copyCode(code),!code); }

  function renderDashboard() {
    const expiring=licenses.filter(l=>licenseStatus(l)==="expiring").sort((a,b)=>new Date(a.expires_at)-new Date(b.expires_at));
    $("stat-total").textContent=String(licenses.length);
    $("stat-total-note").textContent=accounts.filter(a=>a.role==="customer"&&!a.archived).length+" kayıtlı firma";
    $("stat-active").textContent=String(licenses.filter(l=>["active","expiring"].includes(licenseStatus(l))).length);
    $("stat-expiring").textContent=String(expiring.length);
    $("stat-devices").textContent=String(licenses.reduce((sum,l)=>sum+Number(l.active_devices||0),0));
    $("nav-license-count").textContent=String(licenses.length);

    const recent=$("recent-licenses"); recent.replaceChildren();
    if(!licenses.length)recent.append(emptyState("Henüz lisans yok","Yeni lisans oluşturarak başlayın."));
    else licenses.slice(0,5).forEach(license=>{
      const row=el("div","recent-item"),company=el("div","recent-company");
      company.append(el("strong","",license.display_name||"Adsız firma"),el("small","",dateTime(license.created_at,false)));
      row.append(company,el("code","recent-code",license.code||"Kod yok"),statusPill(licenseStatus(license)));
      row.tabIndex=0;row.setAttribute("role","button");row.setAttribute("aria-label",(license.display_name||"Firma")+" lisans ayrıntılarını aç");
      row.addEventListener("click",()=>openLicenseDetails(license));
      row.addEventListener("keydown",event=>{if(event.key==="Enter"||event.key===" "){event.preventDefault();openLicenseDetails(license);}});
      recent.append(row);
    });

    const list=$("expiring-list"); list.replaceChildren();
    $("expiring-badge").textContent=expiring.length+" lisans";
    if(!expiring.length)list.append(emptyState("Yakında sona erecek lisans yok","Süresi 14 gün içinde dolacak lisanslar burada görünür."));
    else expiring.slice(0,6).forEach(license=>{
      const days=Math.max(0,daysUntil(license.expires_at)),row=el("div","expiring-item"),firm=el("div","");
      firm.append(el("strong","",license.display_name||"Adsız firma"),el("small","",dateTime(license.expires_at,false)));
      const track=el("div","expiry-track"),bar=el("span");bar.style.width=Math.max(6,Math.min(100,((14-days)/14)*100))+"%";track.append(bar);
      row.append(firm,track,button(days===0?"Bugün doluyor":days+" gün kaldı","row-primary",()=>openLicenseDetails(license)));
      list.append(row);
    });
  }

  function renderLicenses() {
    const query=$("license-search").value.trim().toLocaleLowerCase("tr-TR"),filter=$("license-filter").value;
    const filtered=licenses.filter(license=>{
      const status=licenseStatus(license),search=[license.display_name,license.code,license.id].join(" ").toLocaleLowerCase("tr-TR");
      return (filter==="all"||status===filter)&&search.includes(query);
    });
    $("license-result-count").textContent=filtered.length+" lisans";
    const target=$("license-table");target.replaceChildren();
    if(!filtered.length){target.append(emptyState("Eşleşen lisans bulunamadı",query?"Arama metnini veya durum filtresini değiştirin.":"Bu görünümde lisans kaydı yok."));return;}
    const rows=filtered.map(license=>{
      const code=el("div","license-code-cell");code.append(el("code","",license.code||"Henüz kod yok"),copyButton(license.code));
      const usage=Number(license.active_devices||0)+" / "+(Number(license.device_limit)===0?"Sınırsız":license.device_limit);
      return [companyCell(license.display_name,"Lisans #"+license.id),code,planPills(license),el("span","device-usage",usage),
        license.expires_at?dateTime(license.expires_at,false):pill("Süresiz","status-pill perpetual"),
        statusPill(licenseStatus(license)),el("div","row-actions")];
    });
    rows.forEach((row,index)=>row[6].append(button("Yönet","row-primary",()=>openLicenseDetails(filtered[index]))));
    target.append(table(["FİRMA / KAYIT","LİSANS KODU","LİSANS HAKKI","CİHAZ","BİTİŞ TARİHİ","DURUM",""],rows));
  }

  async function changeAccount(account,action) {
    if(action==="status") {
      if(!account.disabled) {
        const yes=await askConfirmation({title:"Hesap devre dışı bırakılsın mı?",message:account.display_name+" hesabının oturumları kapatılacak ve yeniden giriş yapması engellenecek.",acceptLabel:"Devre dışı bırak"});
        if(!yes)return;
      }
      await api("/api/admin/accounts/"+account.id+"/status","PATCH",{disabled:!account.disabled});
      await refresh();showNotice("Hesap durumu güncellendi.","success");return;
    }
    if(action==="archive"||action==="restore") {
      const restoring=action==="restore";
      const yes=await askConfirmation({title:restoring?"Hesap arşivden çıkarılsın mı?":"Hesap arşivlensin mi?",message:account.display_name+(restoring?" hesabı yeniden kullanılabilir olacak.":" hesabı listeden kaldırılacak ve oturumları kapatılacak."),acceptLabel:restoring?"Geri al":"Arşivle",danger:false});
      if(!yes)return;
      await api("/api/admin/accounts/"+account.id+"/manage","POST",{action});
      await refresh();showNotice("Hesap işlemi tamamlandı.","success");return;
    }
    const message=account.role==="customer"
      ?account.display_name+" ve bu firmaya bağlı lisanslar ile destek kayıtları kalıcı olarak silinecek."
      :account.display_name+" hesabı kalıcı olarak silinecek. Atanmış işler havuza döner.";
    const yes=await askConfirmation({title:"Hesap kalıcı olarak silinsin mi?",message:message+" Onaylamak için firma/kullanıcı adını aynen yazın.",phrase:account.display_name,phraseLabel:"Silmek için adı aynen yazın",acceptLabel:"Kalıcı sil"});
    if(!yes)return;
    await api("/api/admin/accounts/"+account.id+"/manage","POST",{action:"delete",confirmation:account.display_name});
    await refresh();showNotice("Hesap kalıcı olarak silindi.","success");
  }

  function resetPasswordVisibility(root) {
    root.querySelectorAll("[data-password-toggle]").forEach(button=>{
      const input=$(button.dataset.target);input.type="password";button.textContent="Göster";button.setAttribute("aria-pressed","false");
    });
  }
  function openPasswordDialog(account) {
    passwordAccount=account;
    const form=$("change-password-form"),self=account.id===currentAccountId;
    form.reset();resetPasswordVisibility(form);
    $("password-account-name").textContent=account.display_name;
    $("current-password-wrap").hidden=!self;
    $("current-password").required=self;
    $("password-session-note").textContent=self
      ?"Kendi parolanızı değiştirmek için mevcut parolanızı doğrulayın. Kaydedince oturumunuz kapanır."
      :"Yeni parola kaydedilince bu hesaba ait tüm açık oturumlar kapatılır.";
    $("password-error").hidden=true;$("password-error").textContent="";
    $("change-password-dialog").showModal();
  }

  function renderAccounts() {
    const query=$("account-search").value.trim().toLocaleLowerCase("tr-TR"),includeArchived=$("show-archived-accounts").checked;
    const filtered=accounts.filter(account=>{
      const searchable=[account.display_name,account.username,roleNames[account.role],account.id].join(" ").toLocaleLowerCase("tr-TR");
      return (includeArchived||!account.archived)&&searchable.includes(query);
    });
    $("account-result-count").textContent=filtered.length+" hesap";
    const target=$("account-table");target.replaceChildren();
    if(!filtered.length){target.append(emptyState("Eşleşen hesap bulunamadı",query?"Arama metnini değiştirin.":"Henüz firma veya yetkili hesabı yok."));return;}
    const rows=filtered.map(account=>{
      const role=pill(roleNames[account.role]||account.role,"role-pill "+account.role);
      const state=account.archived?statusPill("archived"):account.disabled?statusPill("disabled"):statusPill("active");
      const details=account.role==="customer"?(account.license_count||0)+" lisans · "+(account.ticket_count||0)+" destek kaydı":"Yetkili kullanıcı";
      const soleActiveAdmin=account.role==="admin"&&!account.disabled&&!account.archived&&accounts.filter(a=>a.role==="admin"&&!a.disabled&&!a.archived).length<=1;
      const actions=el("div","row-actions");
      if(account.role!=="customer")actions.append(button("Parola","secondary-button",()=>openPasswordDialog(account)));
      actions.append(
        button(account.disabled?"Etkinleştir":"Devre dışı","row-primary",()=>changeAccount(account,"status"),account.id===currentAccountId||soleActiveAdmin&&!account.disabled),
        button(account.archived?"Arşivden çıkar":"Arşivle","secondary-button",()=>changeAccount(account,account.archived?"restore":"archive"),account.id===currentAccountId&&!account.archived||soleActiveAdmin&&!account.archived),
        button("Kalıcı sil","danger-link",()=>changeAccount(account,"delete"),account.id===currentAccountId||soleActiveAdmin)
      );
      return [companyCell(account.display_name,account.role==="customer"?"Firma #"+account.id:"Kullanıcı adı: "+account.username),role,state,details,dateTime(account.created_at,false),actions];
    });
    target.append(table(["FİRMA / KULLANICI","ROL","DURUM","KAYITLAR","OLUŞTURULMA","İŞLEMLER"],rows));
  }

  function renderAudit() {
    const query=$("audit-search").value.trim().toLocaleLowerCase("tr-TR");
    const filtered=history.filter(item=>[item.actor_display_name,item.action,item.object_type,item.object_id,JSON.stringify(item.details||{})].join(" ").toLocaleLowerCase("tr-TR").includes(query));
    $("audit-result-count").textContent=filtered.length+" / "+history.length+" işlem";
    const target=$("audit-table");target.replaceChildren();
    if(!filtered.length){target.append(emptyState("Eşleşen işlem bulunamadı",query?"Arama metnini değiştirin.":"Henüz işlem kaydı yok."));return;}
    target.append(table(["TARİH","İŞLEMİ YAPAN","İŞLEM","KAYIT","AYRINTI"],filtered.map(item=>{
      const details=JSON.stringify(item.details||{});
      return [dateTime(item.created_at),item.actor_display_name||"Silinmiş kullanıcı",item.action||"—",(item.object_type||"Kayıt")+" #"+(item.object_id||"—"),details==="{}"?"—":details];
    })));
  }

  function renderAll(){renderDashboard();renderLicenses();renderAccounts();renderAudit();}
  function navigate(view) {
    if(!viewNames[view])return;
    document.querySelectorAll(".view-page").forEach(section=>section.hidden=section.id!=="view-"+view);
    document.querySelectorAll(".nav-item").forEach(button=>{
      const active=button.dataset.view===view;button.classList.toggle("active",active);
      if(active)button.setAttribute("aria-current","page");else button.removeAttribute("aria-current");
    });
    $("page-title").textContent=viewNames[view];window.scrollTo({top:0,behavior:"smooth"});
  }
  function updateCustomerSelect() {
    const select=$("customer-select"),previous=select.value;select.replaceChildren(new Option("Yeni firma oluştur",""));
    accounts.filter(a=>a.role==="customer"&&!a.archived&&!a.disabled).forEach(a=>select.append(new Option(a.display_name,String(a.id))));
    if([...select.options].some(option=>option.value===previous))select.value=previous;
    updateCompanyField();
  }
  function updateCompanyField() {
    const existing=!!$("customer-select").value;$("firm-name-label").hidden=existing;$("firm-name").required=!existing;
  }
  function updateLicenseDuration() {
    const trial=$("license-kind").value==="trial",duration=$("license-duration");
    duration.required=trial;duration.max=trial?"90":"36500";
    duration.placeholder=trial?"1–90 gün":"Standart lisans süresiz";
    $("duration-hint").textContent=trial?"Deneme lisansı 1–90 gün olmalıdır.":"Boş bırakırsanız lisans süresiz olur.";
    if(!trial&&duration.dataset.trialDefault==="true"){duration.value="";duration.dataset.trialDefault="false";}
    if(trial&&(!duration.value||Number(duration.value)>90)){duration.value="7";duration.dataset.trialDefault="true";}
  }

  async function refresh() {
    const values=await Promise.all([api("/api/admin/accounts"),api("/api/admin/license-codes"),api("/api/admin/audit")]);
    [accounts,licenses,history]=values;updateCustomerSelect();renderAll();
    if(selectedLicense) {
      selectedLicense=licenses.find(item=>item.id===selectedLicense.id)||null;
      if(selectedLicense&&$("license-detail-dialog").open)renderLicenseDetails();
      if(!selectedLicense&&$("license-detail-dialog").open)$("license-detail-dialog").close();
    }
  }
  function summaryCell(label,value) {
    const cell=el("div","summary-cell");cell.append(el("span","",label),el("strong","",value));return cell;
  }
  function renderLicenseDetails() {
    const license=selectedLicense;if(!license)return;
    $("detail-license-id").textContent="#"+license.id;
    $("detail-firm-name").textContent=license.display_name||"Adsız firma";
    $("detail-subtitle").textContent=(license.license_kind==="trial"?"Deneme lisansı":"Standart lisans")+" · Oluşturulma: "+dateTime(license.created_at,false);
    $("detail-code").textContent=license.code||"Bu lisans için kod görüntülenemiyor";
    $("copy-license-code").disabled=!license.code;
    const form=$("license-settings-form");
    form.elements.device_limit.value=license.device_limit;
    form.elements.support_enabled.checked=!!license.support_enabled;
    $("renew-duration").value="";
    $("renew-duration").max=license.license_kind==="trial"?"90":"36500";
    $("renew-duration").required=license.license_kind==="trial";
    $("renew-duration").placeholder=license.license_kind==="trial"?"1–90 gün":"Standart lisansı süresiz yap";
    $("renew-hint").textContent=license.license_kind==="trial"?"Deneme lisansında 1–90 gün girin. Süre mevcut bitiş tarihine eklenir.":"Gün girerseniz mevcut bitiş tarihine eklenir. Boş bırakmak lisansı süresiz yapar.";
    const cap=Number(license.device_limit)===0?"Sınırsız":String(license.device_limit);
    $("detail-summary").replaceChildren(
      summaryCell("DURUM",statusNames[licenseStatus(license)]||"—"),
      summaryCell("LİSANS HAKKI",license.support_enabled?"Kullanım + destek":"Yalnız kullanım"),
      summaryCell("CİHAZ",(license.active_devices||0)+" / "+cap),
      summaryCell("BİTİŞ",license.expires_at?dateTime(license.expires_at,false):"Süresiz")
    );
    $("detail-device-count").textContent="("+(license.active_devices||0)+")";
    $("toggle-license-archive").textContent=license.archived?"Arşivden çıkar":"Arşivle";
    $("revoke-license").disabled=!!license.revoked;
    $("revoke-license").textContent=license.revoked?"Lisans iptal edilmiş":"Lisansı iptal et";
    $("convert-trial").hidden=license.license_kind!=="trial";
  }
  function openLicenseDetails(license) {
    selectedLicense=license;renderLicenseDetails();$("license-detail-dialog").showModal();
  }
  async function performLicenseAction(action,body,message) {
    if(!selectedLicense)return;
    const id=selectedLicense.id;
    await api("/api/admin/licenses/"+id+"/manage","POST",{action,...(body||{})});
    await refresh();
    if(selectedLicense&&selectedLicense.id===id)renderLicenseDetails();
    if(message)showNotice(message,"success");
  }
  async function confirmLicenseAction(action) {
    const license=selectedLicense;if(!license)return;
    if(action==="rotate") {
      const yes=await askConfirmation({title:"Lisans kodu yenilensin mi?",message:"Yeni bir kod üretilecek. Eski kodla giriş yapılamaz ve o kodla açılmış oturumlar kapanır.",acceptLabel:"Yeni kod üret",danger:false});
      if(yes)await performLicenseAction("rotate",null,"Lisans kodu yenilendi. Yeni kod ayrıntı penceresinde hazır.");
    } else if(action==="revoke") {
      const yes=await askConfirmation({title:"Lisans iptal edilsin mi?",message:"Bu lisansla yapılan girişler ve mevcut oturumlar durdurulur. Süre uzatılarak yeniden etkinleştirilebilir.",acceptLabel:"Lisansı iptal et"});
      if(yes)await performLicenseAction("revoke",null,"Lisans iptal edildi.");
    } else if(action==="archive"||action==="restore") {
      const restore=action==="restore";
      const yes=await askConfirmation({title:restore?"Lisans arşivden çıkarılsın mı?":"Lisans arşivlensin mi?",message:restore?"Lisans yeniden günlük listelerde görünür olacak.":"Lisans gizlenir ve bu kodla açılmış oturumlar kapatılır.",acceptLabel:restore?"Arşivden çıkar":"Arşivle",danger:false});
      if(yes)await performLicenseAction(action,null,restore?"Lisans arşivden çıkarıldı.":"Lisans arşivlendi.");
    } else if(action==="delete") {
      const yes=await askConfirmation({title:"Lisans kalıcı olarak silinsin mi?",message:license.display_name+" firmasına ait bu lisans kaydı kalıcı olarak silinecek. Bu işlem geri alınamaz. Onaylamak için firma adını aynen yazın.",phrase:license.display_name,phraseLabel:"Silmek için firma adını aynen yazın",acceptLabel:"Kalıcı sil"});
      if(yes)await performLicenseAction("delete",{confirmation:license.display_name},"Lisans kalıcı olarak silindi.");
    }
  }

  async function renderDevices() {
    const license=currentDeviceLicense;if(!license)return;
    $("devices-heading").textContent=(license.display_name||"Firma")+" · Cihazlar";
    const target=$("devices-table");target.replaceChildren(emptyState("Cihazlar yükleniyor",""));
    const devices=await api("/api/admin/licenses/"+license.id+"/devices");
    if(!currentDeviceLicense||currentDeviceLicense.id!==license.id)return;
    target.replaceChildren();
    if(!devices.length){target.append(emptyState("Etkinleştirilmiş cihaz yok","Bu lisansla henüz cihaz girişi yapılmadı."));return;}
    const rows=devices.map(device=>{
      const restore=!!device.revoked_at;
      const action=button(restore?"Yeniden izin ver":"Cihazı kaldır",restore?"row-primary":"danger-button",async()=>{
        const yes=await askConfirmation({title:restore?"Cihaza yeniden izin verilsin mi?":"Cihaz lisans erişimini kaybetsin mi?",message:restore?"Cihaz yeniden giriş yapabilir; eski oturumları geri gelmez.":"Cihazın oturumu kapatılır ve lisans cihaz sınırındaki yeri boşaltılır.",acceptLabel:restore?"Yeniden izin ver":"Cihazı kaldır",danger:!restore});
        if(!yes)return;
        await api("/api/admin/licenses/"+license.id+"/devices/"+encodeURIComponent(device.device_id)+"/manage","POST",{action:restore?"restore":"revoke"});
        await refresh();currentDeviceLicense=licenses.find(item=>item.id===license.id)||null;
        if(currentDeviceLicense)await renderDevices();
        showNotice(restore?"Cihaza yeniden izin verildi.":"Cihaz kaldırıldı ve oturumu kapatıldı.","success");
      });
      return [device.device_name||"Adsız cihaz",device.device_id,device.app_version||"—",dateTime(device.first_seen),dateTime(device.last_seen),statusPill(restore?"revoked":"active"),action];
    });
    target.append(table(["CİHAZ","KİMLİK","UYGULAMA SÜRÜMÜ","İLK KULLANIM","SON GÖRÜLME","DURUM",""],rows));
  }
  async function openDevices() {
    if(!selectedLicense)return;currentDeviceLicense=selectedLicense;$("devices-dialog").showModal();
    try{await renderDevices();}catch(error){$("devices-table").replaceChildren(emptyState("Cihaz listesi yüklenemedi",error.message));}
  }
  async function submitWithButton(event,button,operation) {
    event.preventDefault();button.disabled=true;
    try{await operation();}catch(error){showNotice(error.message||"İşlem tamamlanamadı.","error");}
    finally{button.disabled=false;}
  }

  $("login-form").addEventListener("submit",async event=>{
    const form=event.currentTarget,submit=form.querySelector("button[type=submit]");
    await submitWithButton(event,submit,async()=>{
      const result=await api("/api/auth/login","POST",Object.fromEntries(new FormData(form)));
      if(!result.account||result.account.role!=="admin")throw new Error("Yönetici hesabı gerekli.");
      token=result.access_token;currentAccountId=result.account.id;
      $("identity").textContent=result.account.display_name+" · Yönetici";
      $("identity-avatar").textContent=(result.account.display_name||"Y").trim().slice(0,1).toLocaleUpperCase("tr-TR");
      $("login-screen").hidden=true;$("app-shell").hidden=false;form.reset();
      await refresh();navigate("dashboard");showNotice("Yönetim paneline giriş yapıldı.","success");
    });
  });
  $("license-form").addEventListener("submit",async event=>{
    const form=event.currentTarget,submit=form.querySelector("button[type=submit]");
    await submitWithButton(event,submit,async()=>{
      const values=Object.fromEntries(new FormData(form));
      const body={display_name:values.display_name?values.display_name.trim():"",license_kind:values.license_kind,device_limit:Number(values.device_limit),support_enabled:form.elements.support_enabled.checked};
      if(values.account_id)body.account_id=Number(values.account_id);
      if(values.duration_days)body.duration_days=Number(values.duration_days);
      const created=await api("/api/admin/firm-licenses","POST",body);
      $("create-license-dialog").close();form.reset();updateLicenseDuration();updateCompanyField();await refresh();
      const fresh=licenses.find(item=>item.id===created.id);if(fresh)openLicenseDetails(fresh);
      showNotice("Lisans oluşturuldu. Kod ayrıntı penceresinde hazır.","success");
    });
  });
  $("account-form").addEventListener("submit",async event=>{
    const form=event.currentTarget,submit=form.querySelector("button[type=submit]");
    await submitWithButton(event,submit,async()=>{
      await api("/api/admin/accounts","POST",Object.fromEntries(new FormData(form)));
      $("create-account-dialog").close();form.reset();resetPasswordVisibility(form);await refresh();showNotice("Yetkili hesabı oluşturuldu.","success");
    });
  });
  $("change-password-form").addEventListener("submit",async event=>{
    event.preventDefault();
    const form=event.currentTarget,submit=form.querySelector("button[type=submit]"),account=passwordAccount;
    if(!account)return;
    const newPassword=$("change-password-new").value,confirmation=$("change-password-confirm").value;
    if(newPassword!==confirmation){$("password-error").textContent="Yeni parola alanları eşleşmiyor.";$("password-error").hidden=false;return;}
    submit.disabled=true;$("password-error").hidden=true;
    const body={new_password:newPassword};
    if(account.id===currentAccountId)body.current_password=$("current-password").value;
    try{
      const result=await api("/api/admin/accounts/"+account.id+"/password","POST",body);
      $("change-password-dialog").close();form.reset();resetPasswordVisibility(form);passwordAccount=null;
      if(result.session_invalidated){logout();showNotice("Parola değiştirildi. Yeni parolanızla tekrar giriş yapın.","success");}
      else{
        try{await refresh();showNotice(account.display_name+" hesabının parolası güncellendi; eski oturumları kapatıldı.","success");}
        catch(error){showNotice("Parola güncellendi ancak işlem geçmişi yenilenemedi: "+error.message,"error");}
      }
    }catch(error){
      if($("login-screen").hidden===false)showNotice(error.message||"Parola güncellenemedi.","error");
      else{$("password-error").textContent=error.message||"Parola güncellenemedi.";$("password-error").hidden=false;}
    }
    finally{submit.disabled=false;}
  });
  $("create-account-dialog").addEventListener("close",()=>{
    const form=$("account-form");form.reset();resetPasswordVisibility(form);
  });
  $("change-password-dialog").addEventListener("close",()=>{
    const form=$("change-password-form");form.reset();resetPasswordVisibility(form);passwordAccount=null;
  });
  $("license-settings-form").addEventListener("submit",async event=>{
    const form=event.currentTarget,submit=form.querySelector("button[type=submit]");
    await submitWithButton(event,submit,async()=>{
      if(selectedLicense)await performLicenseAction("configure",{device_limit:Number(form.elements.device_limit.value),support_enabled:form.elements.support_enabled.checked},"Lisans hakları güncellendi.");
    });
  });
  $("renew-form").addEventListener("submit",async event=>{
    const form=event.currentTarget,submit=form.querySelector("button[type=submit]");
    await submitWithButton(event,submit,async()=>{
      if(!selectedLicense)return;const value=form.elements.duration_days.value.trim(),body={};
      if(value)body.duration_days=Number(value);
      await performLicenseAction("renew",body,"Lisans süresi güncellendi.");
    });
  });
  $("convert-trial").addEventListener("click",async()=>{
    if(!selectedLicense)return;
    const yes=await askConfirmation({title:"Standart lisansa dönüştürülsün mü?",message:"Lisans türü standart olur; mevcut bitiş tarihi, cihaz sınırı ve destek hakkı korunur.",acceptLabel:"Standart lisansa dönüştür",danger:false});
    if(yes)try{await performLicenseAction("configure",{license_kind:"standard"},"Lisans standart türe dönüştürüldü.");}catch(error){showNotice(error.message,"error");}
  });
  $("open-license-devices").addEventListener("click",openDevices);
  $("copy-license-code").addEventListener("click",async()=>{try{if(selectedLicense)await copyCode(selectedLicense.code);}catch(error){showNotice(error.message,"error");}});
  $("rotate-license-code").addEventListener("click",async()=>{try{await confirmLicenseAction("rotate");}catch(error){showNotice(error.message,"error");}});
  $("toggle-license-archive").addEventListener("click",async()=>{try{if(selectedLicense)await confirmLicenseAction(selectedLicense.archived?"restore":"archive");}catch(error){showNotice(error.message,"error");}});
  $("revoke-license").addEventListener("click",async()=>{try{await confirmLicenseAction("revoke");}catch(error){showNotice(error.message,"error");}});
  $("delete-license").addEventListener("click",async()=>{try{await confirmLicenseAction("delete");}catch(error){showNotice(error.message,"error");}});

  $("confirm-form").addEventListener("submit",event=>{
    event.preventDefault();const expected=$("confirm-word").placeholder;
    if(expected&&$("confirm-word").value!==expected){$("confirm-error").textContent="Girdiğiniz metin eşleşmiyor. Firma adını aynı şekilde yazın.";$("confirm-error").hidden=false;return;}
    resolveConfirmation(true);
  });
  document.querySelectorAll("[data-confirm-cancel]").forEach(button=>button.addEventListener("click",()=>resolveConfirmation(false)));
  $("confirm-dialog").addEventListener("cancel",event=>{event.preventDefault();resolveConfirmation(false);});
  $("confirm-dialog").addEventListener("close",()=>{if(confirmationResolver)resolveConfirmation(false);});
  document.querySelectorAll("[data-close-dialog]").forEach(button=>button.addEventListener("click",()=>button.closest("dialog").close()));
  document.querySelectorAll("[data-password-toggle]").forEach(button=>button.addEventListener("click",()=>{
    const input=$(button.dataset.target),visible=input.type==="password";
    input.type=visible?"text":"password";button.textContent=visible?"Gizle":"Göster";button.setAttribute("aria-pressed",String(visible));
  }));
  document.querySelectorAll("[data-open-create-license]").forEach(button=>button.addEventListener("click",()=>{
    $("license-form").reset();updateLicenseDuration();updateCompanyField();$("create-license-dialog").showModal();
  }));
  $("open-create-account").addEventListener("click",()=>{$("account-form").reset();resetPasswordVisibility($("account-form"));$("create-account-dialog").showModal();});
  document.querySelectorAll("[data-view]").forEach(button=>button.addEventListener("click",()=>navigate(button.dataset.view)));
  document.querySelectorAll("[data-go-view]").forEach(button=>button.addEventListener("click",()=>navigate(button.dataset.goView)));
  $("customer-select").addEventListener("change",updateCompanyField);
  $("license-kind").addEventListener("change",updateLicenseDuration);
  $("license-duration").addEventListener("input",event=>{event.currentTarget.dataset.trialDefault="false";});
  $("license-search").addEventListener("input",renderLicenses);
  $("license-filter").addEventListener("change",renderLicenses);
  $("account-search").addEventListener("input",renderAccounts);
  $("show-archived-accounts").addEventListener("change",renderAccounts);
  $("audit-search").addEventListener("input",renderAudit);
  $("refresh").addEventListener("click",async event=>{
    const control=event.currentTarget;control.disabled=true;control.querySelector("span").classList.add("spin");
    try{await refresh();showNotice("Veriler güncellendi.","success");}catch(error){showNotice(error.message,"error");}
    finally{control.disabled=false;control.querySelector("span").classList.remove("spin");}
  });
  $("logout").addEventListener("click",async()=>{
    const yes=await askConfirmation({title:"Oturum kapatılsın mı?",message:"Yönetim panelinden çıkış yapılacak.",acceptLabel:"Oturumu kapat",danger:false});
    if(yes){logout();showNotice("Oturum kapatıldı.");}
  });
})();
