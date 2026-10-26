(() => {
  const items = document.querySelectorAll('.reveal');
  if ('IntersectionObserver' in window) {
    const observer = new IntersectionObserver(entries => entries.forEach(entry => {
      if(entry.isIntersecting){entry.target.classList.add('visible');observer.unobserve(entry.target)}
    }),{threshold:.07,rootMargin:'0px 0px 35px 0px'});
    items.forEach(item=>observer.observe(item));
  }else items.forEach(item=>item.classList.add('visible'));
  const reduce = matchMedia('(prefers-reduced-motion: reduce)');
  if (!reduce.matches) {
    const layers=[...document.querySelectorAll('[data-depth]')];let ticking=false;
    const update=()=>{let offset=window.scrollY;layers.forEach(el=>{
      let d=Number(el.dataset.depth||0);el.style.setProperty('--parallax',`${Math.max(-35,Math.min(35,offset*d))}px`)
    });ticking=false};
    window.addEventListener('scroll',()=>{if(!ticking){ticking=true;requestAnimationFrame(update)}},{passive:true});
  }
})();
