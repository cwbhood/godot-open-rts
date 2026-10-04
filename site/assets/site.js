// Ironbound website: mobile menu, screenshot viewer, and the download box.
// No cookies, no analytics. The only network request is to the public GitHub API
// to show the newest release; if that fails the page still works.
(function () {
	"use strict";

	var REPO = "cwbhood/godot-open-rts";
	var RELEASES = "https://github.com/" + REPO + "/releases";

	// Mobile menu
	var toggle = document.querySelector(".nav-toggle");
	var nav = document.getElementById("site-nav");
	if (toggle && nav) {
		toggle.addEventListener("click", function () {
			var open = nav.classList.toggle("open");
			toggle.setAttribute("aria-expanded", open ? "true" : "false");
		});
	}

	// Screenshot viewer: links in .gallery open the big image in a dialog.
	var dialog = document.querySelector(".lightbox");
	if (dialog && typeof dialog.showModal === "function") {
		var img = dialog.querySelector("img");
		var caption = dialog.querySelector(".lightbox-caption");
		dialog.querySelector("button").addEventListener("click", function () { dialog.close(); });
		dialog.addEventListener("click", function (event) { if (event.target === dialog) dialog.close(); });
		document.querySelectorAll(".gallery a").forEach(function (link) {
			link.addEventListener("click", function (event) {
				event.preventDefault();
				var thumb = link.querySelector("img");
				img.src = link.getAttribute("href");
				img.alt = thumb ? thumb.alt : "";
				var fig = link.querySelector("figcaption");
				caption.textContent = fig ? fig.textContent : "";
				dialog.showModal();
			});
		});
	}

	// Download box
	var box = document.querySelector("[data-downloads]");
	if (!box) return;

	// Highlight the visitor's own system. Read locally, never sent anywhere.
	var ua = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.userAgent || "";
	var mine = /win/i.test(ua) ? "windows" : /mac|iphone|ipad/i.test(ua) ? "macos" : /linux|x11|cros/i.test(ua) ? "linux" : "";
	if (mine) {
		var link = box.querySelector('[data-platform="' + mine + '"]');
		if (link) {
			link.classList.add("is-yours");
			var hint = link.querySelector("[data-yours]");
			if (hint) hint.hidden = false;
		}
	}

	var line = box.querySelector("[data-release-line]");
	var none = box.querySelector("[data-no-release]");

	function noRelease() {
		box.querySelectorAll("[data-platform]").forEach(function (a) { a.href = RELEASES; });
		if (line) line.textContent = "No public release yet";
		if (none) none.hidden = false;
	}

	function size(bytes) {
		return bytes > 1048576 ? Math.round(bytes / 1048576) + " MB" : Math.round(bytes / 1024) + " KB";
	}

	if (!window.fetch) return;
	// The list endpoint answers 200 with [] when nothing is published yet, so the
	// console stays clean before the first release.
	fetch("https://api.github.com/repos/" + REPO + "/releases?per_page=5", { headers: { Accept: "application/vnd.github+json" } })
		.then(function (response) { if (!response.ok) throw new Error(response.status); return response.json(); })
		.then(function (list) {
			var release = (list || []).filter(function (r) { return !r.draft && !r.prerelease; })[0];
			if (!release) throw new Error("no release");
			var date = (release.published_at || "").slice(0, 10);
			if (line) line.textContent = release.name || release.tag_name + (date ? " · " + date : "");
			(release.assets || []).forEach(function (asset) {
				var a = box.querySelector('[data-asset="' + asset.name + '"]');
				if (!a) return;
				a.href = asset.browser_download_url;
				var s = a.querySelector("[data-size]");
				if (s) s.textContent = "zip, " + size(asset.size);
			});
			var notes = box.querySelector("[data-release-notes]");
			if (notes) { notes.href = release.html_url; notes.hidden = false; }
		})
		.catch(noRelease);
})();
