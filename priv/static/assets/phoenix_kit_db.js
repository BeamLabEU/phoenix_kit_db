// phoenix_kit_db JS hooks — folded into the host LiveSocket by core's
// :phoenix_kit_js_sources compiler (see PhoenixKit.Module.js_sources/0).
//
// A hook must be in the host's LiveSocket when it is CONSTRUCTED. This one
// used to register itself from an inline <script> at the bottom of
// show_live.html.heex, which works on a hard page load — the script runs
// during HTML parse, before app.js snapshots window.PhoenixKitHooks — and
// silently does nothing after a LiveView navigation, because morphdom never
// executes an inserted <script> and the hooks map is already fixed.
//
// The hook name is namespaced because the final fold into
// window.PhoenixKitHooks is last-write-wins across every module's bundle and
// core's own hooks.
(function () {
  "use strict";

  window.PhoenixKitDbHooks = window.PhoenixKitDbHooks || {};
  var hooks = window.PhoenixKitDbHooks;

  if (hooks.PhoenixKitDbTableScroller) return;

  hooks.PhoenixKitDbTableScroller = {
    mounted() {
      this.scrollbar = this.el.querySelector('#fake-scrollbar');
      this.pageMarkers = this.el.querySelector('#page-markers');

      this.pendingPage = null;
      this.debounceTimer = null;
      this.markerHideTimer = null;
      this.isHoldingScrollbar = false;
      this.isHovering = false;
      this.page = parseInt(this.el.dataset.page || '1', 10);
      this.totalPages = parseInt(this.el.dataset.totalPages || '1', 10);

      requestAnimationFrame(() => this.syncScrollToPage());

      if (this.scrollbar) {
        this.scrollHandler = this.handleScroll.bind(this);
        this.scrollbar.addEventListener('scroll', this.scrollHandler, { passive: true });

        this.scrollbar.addEventListener('mouseenter', () => {
          this.isHovering = true;
          this.showMarkers();
        });

        this.scrollbar.addEventListener('mouseleave', () => {
          this.isHovering = false;
          if (this.isHoldingScrollbar) {
            this.isHoldingScrollbar = false;
            this.snapToPage();
          }
          this.hideMarkersDelayed();
        });

        this.scrollbar.addEventListener('mousedown', () => {
          this.isHoldingScrollbar = true;
        });
        this.scrollbar.addEventListener('mouseup', () => {
          this.isHoldingScrollbar = false;
          this.snapToPage();
        });
      }
    },

    updated() {
      const newPage = parseInt(this.el.dataset.page || '1', 10);
      const newTotalPages = parseInt(this.el.dataset.totalPages || '1', 10);

      const newScrollbar = this.el.querySelector('#fake-scrollbar');
      if (newScrollbar !== this.scrollbar) {
        if (this.scrollbar) {
          this.scrollbar.removeEventListener('scroll', this.scrollHandler);
        }
        this.scrollbar = newScrollbar;
        if (this.scrollbar) {
          this.scrollbar.addEventListener('scroll', this.scrollHandler, { passive: true });
          this.scrollbar.addEventListener('mousedown', () => this.showMarkers());
          this.scrollbar.addEventListener('mouseup', () => this.hideMarkersDelayed());
          this.scrollbar.addEventListener('mouseleave', () => this.hideMarkersDelayed());
        }
      }
      this.pageMarkers = this.el.querySelector('#page-markers');

      const pageChanged = newPage !== this.page;
      const totalPagesChanged = newTotalPages !== this.totalPages;

      this.totalPages = newTotalPages;
      this.page = newPage;

      if (pageChanged || totalPagesChanged) {
        requestAnimationFrame(() => this.syncScrollToPage());
      }
    },

    destroyed() {
      if (this.scrollbar) {
        this.scrollbar.removeEventListener('scroll', this.scrollHandler);
      }
      if (this.debounceTimer) clearTimeout(this.debounceTimer);
      if (this.markerHideTimer) clearTimeout(this.markerHideTimer);
    },

    syncScrollToPage() {
      if (!this.scrollbar || this.totalPages <= 1) return;

      const maxScroll = this.scrollbar.scrollHeight - this.scrollbar.clientHeight;
      const targetScroll = ((this.page - 1) / (this.totalPages - 1)) * maxScroll;
      this.scrollbar.scrollTop = targetScroll;
    },

    snapToPage() {
      const page = this.pendingPage || this.page;
      if (!this.scrollbar || this.totalPages <= 1) return;

      const maxScroll = this.scrollbar.scrollHeight - this.scrollbar.clientHeight;
      const targetScroll = ((page - 1) / (this.totalPages - 1)) * maxScroll;
      this.scrollbar.scrollTop = targetScroll;
    },

    showMarkers() {
      if (this.markerHideTimer) {
        clearTimeout(this.markerHideTimer);
        this.markerHideTimer = null;
      }
      if (this.pageMarkers) {
        this.pageMarkers.style.opacity = '1';
        this.updateMarkerStyles();
      }
    },

    hideMarkersDelayed() {
      if (this.markerHideTimer) clearTimeout(this.markerHideTimer);
      this.markerHideTimer = setTimeout(() => {
        if (this.pageMarkers) {
          this.pageMarkers.style.opacity = '0';
        }
      }, 300);
    },

    updateMarkerStyles() {
      if (!this.pageMarkers || !this.scrollbar) return;

      const markers = this.pageMarkers.querySelectorAll('.page-marker');
      if (!markers.length) return;

      const maxScroll = this.scrollbar.scrollHeight - this.scrollbar.clientHeight;
      const scrollPercent = maxScroll > 0 ? this.scrollbar.scrollTop / maxScroll : 0;
      const currentPage = scrollPercent * (this.totalPages - 1) + 1;
      const focusPercent = (currentPage - 1) / (this.totalPages - 1);

      const markerAreaHeight = this.pageMarkers.offsetHeight || this.scrollbar.clientHeight;
      const pixelsPerPage = markerAreaHeight / this.totalPages;

      const densityFactor = Math.min(Math.max((pixelsPerPage - 5) / 15, 0), 1);
      const effectStrength = 1 - densityFactor;

      const baseFontSize = 8 + 6 * densityFactor;
      const maxScale = 1 + 1.2 * effectStrength;
      const minScale = 1 - 0.6 * effectStrength;
      const maxOffset = 22 * effectStrength;
      const falloffRange = 3 + 4 * densityFactor;
      const compressionStrength = 0.4 * effectStrength;

      markers.forEach(marker => {
        const page = parseInt(marker.dataset.page, 10);
        const distance = Math.abs(page - currentPage);
        const originalPos = (page - 1) / (this.totalPages - 1);

        let newPos = originalPos;
        if (compressionStrength > 0.01) {
          const delta = originalPos - focusPercent;
          const expandedDelta = Math.sign(delta) * Math.pow(Math.abs(delta), 1 - compressionStrength);
          newPos = focusPercent + expandedDelta;
        }

        const t = Math.min(distance / falloffRange, 1);
        const scale = maxScale - (maxScale - minScale) * t;
        const offset = maxOffset * (1 - t);

        marker.style.top = `${newPos * 100}%`;
        marker.style.fontSize = `${baseFontSize}px`;
        marker.style.transform = `translateY(-50%) translateX(-${offset}px) scale(${scale})`;

        const minOpacity = 0.3 + 0.7 * densityFactor;
        marker.style.opacity = minOpacity + (1 - minOpacity) * (1 - t * 0.6);
      });
    },

    handleScroll() {
      if (this.totalPages <= 1) return;

      this.showMarkers();

      const maxScroll = this.scrollbar.scrollHeight - this.scrollbar.clientHeight;
      const scrollPercent = this.scrollbar.scrollTop / maxScroll;
      const newPage = Math.round(scrollPercent * (this.totalPages - 1)) + 1;
      const clampedPage = Math.max(1, Math.min(newPage, this.totalPages));

      this.pendingPage = clampedPage;

      if (this.debounceTimer) clearTimeout(this.debounceTimer);

      this.debounceTimer = setTimeout(() => {
        this.debounceTimer = null;

        if (this.pendingPage !== this.page) {
          this.page = this.pendingPage;
          this.pushEvent('change_page', { page: this.pendingPage });
        }

        this.hideMarkersDelayed();
      }, 100);
    }
  };
})();
