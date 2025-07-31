const notice = (msg) => new Notice(msg, 5000);
const log = (msg) => console.log(msg);

const API_URL = "https://api.igdb.com/v4/games";
const AUTH_URL = "https://id.twitch.tv/oauth2/token";
const GRANT_TYPE = "client_credentials";

const API_CLIENT_ID_OPTION = "IGDB API Client ID";
const API_CLIENT_SECRET_OPTION = "IGDB API Client secret";

var userData = { igdbToken: "" };
var AUTH_TOKEN;

module.exports = {
	entry: start,
	settings: {
		name: "Videogames Script",
		author: "Elaws",
		options: {
			[API_CLIENT_ID_OPTION]: {
				type: "text",
				defaultValue: "",
				placeholder: "IGDB API Client ID",
			},
			[API_CLIENT_SECRET_OPTION]: {
				type: "text",
				defaultValue: "",
				placeholder: "IGDB API Client secret",
			},
		},
	},
};

let QuickAdd;
let Settings;
let savePath;

async function start(params, settings) {
	QuickAdd = params;
	Settings = settings;

	var relativePath = QuickAdd.app.vault.configDir;
	savePath = QuickAdd.obsidian.normalizePath(`${relativePath}/igdbToken.json`);

	// Retrieve saved token or create and save one (in Obsidian's system directory as igdbToken.json)
	// Token is generated from client ID and client secret, and lasts 2 months.
	// Token is refreshed when request fails because of invalid token (every two months)
	await readAuthToken();

	const query = await QuickAdd.quickAddApi.inputPrompt(
		"Enter videogame title: "
	);
	if (!query) {
		notice("No query entered.");
		throw new Error("No query entered.");
	}

	const searchResults = await getByQuery(query);

	const selectedGame = await QuickAdd.quickAddApi.suggester(
		searchResults.map(formatTitleForSuggestion),
		searchResults
	);
	if (!selectedGame) {
		notice("No choice selected.");
		throw new Error("No choice selected.");
	}

	if (selectedGame.involved_companies) {
		var developer = selectedGame.involved_companies.find(
			(element) => element.developer
		);
	}

	// Get rating from aggregated_rating or rating and format it
	let gameRating = 0;
	if (selectedGame.aggregated_rating) {
		const ratingValue = (selectedGame.aggregated_rating / 10).toFixed(2);
		gameRating = ratingValue;
	} else if (selectedGame.rating) {
		const ratingValue = (selectedGame.rating / 10).toFixed(2);
		gameRating = ratingValue;
	}

	// Get download URL
	let downloadUrl = await QuickAdd.quickAddApi.inputPrompt(
		"Download URL",
		null,
		" "
	);
	let downloadFormatted = " ";
	if (downloadUrl && downloadUrl.trim() !== " " && downloadUrl.trim() !== "") {
		downloadUrl = downloadUrl.trim();
		// Add https:// if no protocol is specified
		if (
			!downloadUrl.startsWith("http://") &&
			!downloadUrl.startsWith("https://")
		) {
			downloadUrl = "https://" + downloadUrl;
		}
		downloadFormatted = downloadUrl;
	}

	QuickAdd.variables = {
		...selectedGame,
		urlName: encodeURIComponent(selectedGame.name),
		download: downloadFormatted,
		fileName: replaceIllegalFileNameCharactersInString(selectedGame.name),
		release: `${selectedGame.first_release_date
			? new Date(selectedGame.first_release_date * 1000).toISOString().split('T')[0]
			: " "
			}`,
    rating: gameRating,
		genresFormatted: `${selectedGame.genres
			? formatList(selectedGame.genres.map((item) => item.name))
			: " "
			}`,
		genresListed: `${selectedGame.genres
			? formatListProperties(
				selectedGame.genres.map((item) => item.name)
			)
			: " "
			}`,
		gameModesFormatted: `${selectedGame.game_modes
			? formatList(selectedGame.game_modes.map((item) => item.name))
			: " "
			}`,
		gameModesListed: `${selectedGame.game_modes
			? formatListProperties(
				selectedGame.game_modes.map((item) => item.name)
			)
			: " "
			}`,
		themesFormatted: `${selectedGame.themes
			? formatList(selectedGame.themes.map((item) => item.name))
			: " "
			}`,
		themesListed: `${selectedGame.themes
			? formatListProperties(
				selectedGame.themes.map((item) => item.name)
			)
			: " "
			}`,
		storylineFormatted: `${selectedGame.storyline
			? selectedGame.storyline.replace(/\n\n/g, '\n>\n> ').replace(/^/, '> ')
			: " "
			}`,
		summaryFormatted: `${selectedGame.summary
			? selectedGame.summary.replace(/\n\n/g, '\n>\n> ').replace(/> /g, '')
			: " "
			}`,
		//Developer name and logo
		developerName: `${developer ? developer.company.name : " "}`,
		developerLogo: `${developer
			? developer.company.logo
				? ("https:" + developer.company.logo.url).replace("thumb", "logo_med")
				: " "
			: " "
			}`,
		// For possible image size options, see : https://api-docs.igdb.com/#images
		thumbnail: `${selectedGame.cover
			? "https:" + selectedGame.cover.url
			: " "
			}`,
    cover: `${selectedGame.cover
			? "https:" + selectedGame.cover.url.replace("thumb", "cover_big")
			: " "
			}`
	};
}

function formatTitleForSuggestion(resultItem) {
	return `${resultItem.name} (${new Date(
		resultItem.first_release_date * 1000
	).getFullYear()})`;
}

async function getByQuery(query) {
	const searchResults = await apiGet(query);

	if (searchResults.message) {
		await refreshAuthToken();
		return await getByQuery(query);
	}

	if (searchResults.length == 0) {
		notice("No results found.");
		throw new Error("No results found.");
	}

	return searchResults;
}

/**
 * Formats a list of items as YAML-style properties with bullet points
 * @param {Array} list - Array of items to format
 * @param {string} propertyName - Name of the property (e.g., "genre", "themes")
 * @returns {string} Formatted string in YAML style with bullet points
 * @example
 * formatListProperties(["Action", "Adventure"], "genre")
 * // Returns: "genre:\n- Action\n- Adventure"
 */
function formatListProperties(list) {
	if (!list || list.length === 0 || list[0] == "N/A") return " ";

	const items = list.map((item) => `- ${item.trim()}`).join("\n");
	return `\n${items}`;
}

function formatList(list) {
	if (list.length === 0 || list[0] == "N/A") return " ";
	if (list.length === 1) return `${list[0]}`;

	return list.map((item) => `\"${item.trim()}\"`).join(", ");
}

function replaceIllegalFileNameCharactersInString(string) {
	return string.replace(/[\\,#%&\{\}\/*<>$\":@.]*/g, "");
}

async function readAuthToken() {
	if (await QuickAdd.app.vault.adapter.exists(savePath)) {
		userData = JSON.parse(await QuickAdd.app.vault.adapter.read(savePath));
		AUTH_TOKEN = userData.igdbToken;
	} else {
		await refreshAuthToken();
	}
}

async function refreshAuthToken() {
	const authResults = await getAuthentified();

	if (!authResults.access_token) {
		notice("Auth token refresh failed.");
		throw new Error("Auth token refresh failed.");
	} else {
		AUTH_TOKEN = authResults.access_token;
		userData.igdbToken = authResults.access_token;
		await QuickAdd.app.vault.adapter.write(savePath, JSON.stringify(userData));
	}
}

async function getAuthentified() {
	let finalURL = new URL(AUTH_URL);

	finalURL.searchParams.append("client_id", Settings[API_CLIENT_ID_OPTION]);
	finalURL.searchParams.append(
		"client_secret",
		Settings[API_CLIENT_SECRET_OPTION]
	);
	finalURL.searchParams.append("grant_type", GRANT_TYPE);

	const res = await request({
		url: finalURL.href,
		method: "POST",
		cache: "no-cache",
		headers: {
			"Content-Type": "application/json",
		},
	});
	return JSON.parse(res);
}

async function apiGet(query) {
	try {
		const res = await request({
			url: API_URL,
			method: "POST",
			cache: "no-cache",
			headers: {
				"Client-ID": Settings[API_CLIENT_ID_OPTION],
				Authorization: "Bearer " + AUTH_TOKEN,
			},
			// The understand syntax of request to IGDB API, read the following :
			// https://api-docs.igdb.com/#examples
			// https://api-docs.igdb.com/#game
			// https://api-docs.igdb.com/#expander
			body:
				'fields name, first_release_date, involved_companies.developer, involved_companies.company.name, involved_companies.company.logo.url, url, cover.url, genres.name, game_modes.name, themes.name, storyline, summary, aggregated_rating, rating; search "' +
				query +
				'"; limit 15;',
		});

		return JSON.parse(res);
	} catch (error) {
		await refreshAuthToken();
		return await getByQuery(query);
	}
}
