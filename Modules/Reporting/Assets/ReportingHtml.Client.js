// PoSh-Backup - ReportingHtml.Client.js
// Client-side JavaScript for interactive HTML reports.

document.addEventListener('DOMContentLoaded', function () {
    // Persistent Collapsible Sections Logic
    const DETAILS_LS_PREFIX = 'poshBackupReport_detailsState_';
    const collapsibleDetailsElements = document.querySelectorAll('details[id^="details-"]');

    collapsibleDetailsElements.forEach(details => {
        const storedState = localStorage.getItem(DETAILS_LS_PREFIX + details.id);
        if (storedState === 'closed' && details.open) { 
            details.removeAttribute('open');
        } else if (storedState === 'open' && !details.open) { 
            details.setAttribute('open', '');
        }
        details.addEventListener('toggle', function() {
            localStorage.setItem(DETAILS_LS_PREFIX + this.id, this.open ? 'open' : 'closed');
        });
    });

    const keywordSearchInput = document.getElementById('logKeywordSearch');
    const levelFilterCheckboxes = document.querySelectorAll('.log-level-filter');
    const logEntriesContainer = document.getElementById('detailedLogEntries');
    const selectAllButton = document.getElementById('logFilterSelectAll');
    const deselectAllButton = document.getElementById('logFilterDeselectAll');
    const filterIndicator = document.getElementById('logFilterActiveIndicator');
    let originalLogMessages = new Map(); 

    if (logEntriesContainer) {
        const logEntries = Array.from(logEntriesContainer.getElementsByClassName('log-entry'));
        logEntries.forEach((entry, index) => { 
            const messageSpan = entry.querySelector('span');
            if (messageSpan) originalLogMessages.set(index, messageSpan.innerHTML);
        });

        if (logEntries.length === 0 && (keywordSearchInput || levelFilterCheckboxes.length > 0)) {
            const filterControlsArea = document.querySelector('.log-filters');
            if(filterControlsArea) filterControlsArea.style.display = 'none';
            if(filterIndicator) filterIndicator.style.display = 'none';
        }

        function highlightText(text, keyword) {
            if (!keyword || !text) return text;
            const specialCharsPattern = '[.*+?^${}()|[\\]\\\\]'; // Corrected: removed extra single quotes around $
            const specialCharsRegex = new RegExp(specialCharsPattern, 'g');
            const escapedKeyword = keyword.replace(specialCharsRegex, '\\$&');
            
            const highlightRegex = new RegExp('(' + escapedKeyword + ')', 'gi');
            return text.replace(highlightRegex, '<span class="search-highlight">$1</span>');
        }

        function filterLogs() {
            const keyword = keywordSearchInput ? keywordSearchInput.value.toLowerCase().trim() : '';
            const activeLevelFilters = new Set();
            let allLevelsUnchecked = true; 
            let defaultLevelsAreChecked = true; 

            if (levelFilterCheckboxes.length > 0) {
                levelFilterCheckboxes.forEach(checkbox => {
                    if (checkbox.checked) {
                        activeLevelFilters.add(checkbox.value.toUpperCase());
                        allLevelsUnchecked = false; 
                    } else {
                        defaultLevelsAreChecked = false; 
                    }
                });
            } else { 
                allLevelsUnchecked = false; 
                defaultLevelsAreChecked = false;
            }

            logEntries.forEach((entry, index) => {
                const messageSpan = entry.querySelector('span');
                let entryTextContent = '';

                if (messageSpan && originalLogMessages.has(index)) { 
                     messageSpan.innerHTML = originalLogMessages.get(index); 
                     entryTextContent = messageSpan.textContent ? messageSpan.textContent.toLowerCase() : '';
                } else if (messageSpan) { 
                     entryTextContent = messageSpan.textContent ? messageSpan.textContent.toLowerCase() : '';
                }
                
                const entryLevel = entry.dataset.level ? entry.dataset.level.toUpperCase() : '';
                const keywordMatch = (keyword === '') || entryTextContent.includes(keyword);
                const levelMatch = allLevelsUnchecked || activeLevelFilters.size === 0 || activeLevelFilters.has(entryLevel);

                if (keywordMatch && levelMatch) {
                    entry.style.display = 'flex'; 
                    if (keyword !== '' && messageSpan) { 
                        messageSpan.innerHTML = highlightText(messageSpan.innerHTML, keyword);
                    }
                } else {
                    entry.style.display = 'none';
                }
            });

            let keywordFilterActive = (keywordSearchInput && keywordSearchInput.value.trim() !== '');
            let levelFilterActive = (levelFilterCheckboxes.length > 0 && !defaultLevelsAreChecked); 
            if (levelFilterCheckboxes.length > 0 && allLevelsUnchecked) { 
                levelFilterActive = true;
            }
            if (levelFilterCheckboxes.length > 0 && defaultLevelsAreChecked && !allLevelsUnchecked && activeLevelFilters.size === levelFilterCheckboxes.length) {
                 levelFilterActive = false;
            }

            const filtersInUse = keywordFilterActive || levelFilterActive;
            if (filterIndicator) {
                filterIndicator.style.display = filtersInUse ? 'inline-block' : 'none';
            }
        }

        if (keywordSearchInput) keywordSearchInput.addEventListener('input', filterLogs);
        if (levelFilterCheckboxes.length > 0) {
            levelFilterCheckboxes.forEach(checkbox => checkbox.addEventListener('change', filterLogs));
            filterLogs(); 
        }
        if (selectAllButton) selectAllButton.addEventListener('click', () => { levelFilterCheckboxes.forEach(cb => cb.checked = true); filterLogs(); });
        if (deselectAllButton) deselectAllButton.addEventListener('click', () => { levelFilterCheckboxes.forEach(cb => cb.checked = false); filterLogs(); });

    } else { 
        if (filterIndicator) filterIndicator.style.display = 'none';
        console.warn('Log entries container "detailedLogEntries" not found.');
    }

    const scrollTopButton = document.getElementById('scrollToTopBtn');
    if (scrollTopButton) {
        window.onscroll = () => { scrollTopButton.style.display = (document.body.scrollTop > 100 || document.documentElement.scrollTop > 100) ? "block" : "none"; };
        scrollTopButton.addEventListener('click', () => { document.body.scrollTop = 0; document.documentElement.scrollTop = 0; });
    }

    document.querySelectorAll('.copy-hook-output-btn').forEach(button => {
        button.addEventListener('click', function() {
            const preElement = this.nextElementSibling; 
            if (preElement && preElement.tagName === 'PRE') {
                navigator.clipboard.writeText(preElement.textContent || preElement.innerText).then(() => {
                    const originalText = this.textContent;
                    this.textContent = 'Copied!';
                    this.disabled = true;
                    setTimeout(() => { this.textContent = originalText; this.disabled = false; }, 2000);
                }).catch(err => console.error('Failed to copy hook output: ', err));
            }
        });
    });

    document.querySelectorAll('table[data-sortable-table]').forEach(makeTableSortable);

    function makeTableSortable(table) {
        const headers = table.querySelectorAll('thead th[data-sortable-column]');
        let currentSort = { columnIndex: -1, order: 'asc' }; 

        headers.forEach((header, colIndex) => {
            header.style.cursor = 'pointer';
            let arrowSpan = header.querySelector('.sort-arrow');
            if (!arrowSpan) { 
                arrowSpan = document.createElement('span');
                arrowSpan.className = 'sort-arrow';
                header.appendChild(arrowSpan);
            }
            header.setAttribute('aria-sort', 'none'); 

            header.addEventListener('click', () => {
                const tbody = table.querySelector('tbody');
                if (!tbody) return;
                const rowsArray = Array.from(tbody.querySelectorAll('tr'));
                
                const sortOrder = (currentSort.columnIndex === colIndex && currentSort.order === 'asc') ? 'desc' : 'asc';
                
                rowsArray.sort((rowA, rowB) => {
                    const cellA_element = rowA.cells[colIndex];
                    const cellB_element = rowB.cells[colIndex];
                    if (!cellA_element || !cellB_element) return 0;

                    const valA = (cellA_element.dataset.sortValue || cellA_element.textContent || '').trim().toLowerCase();
                    const valB = (cellB_element.dataset.sortValue || cellB_element.textContent || '').trim().toLowerCase();
                    
                    const numA = parseFloat(valA.replace(/,/g, '')); 
                    const numB = parseFloat(valB.replace(/,/g, ''));

                    let comparison = 0;
                    if (!isNaN(numA) && !isNaN(numB)) { 
                        comparison = numA - numB;
                    } else { 
                        comparison = valA.localeCompare(valB, undefined, {numeric: true, sensitivity: 'base'});
                    }
                    return sortOrder === 'asc' ? comparison : -comparison;
                });

                rowsArray.forEach(row => tbody.appendChild(row)); 

                headers.forEach(th => {
                    const thArrow = th.querySelector('.sort-arrow');
                    if (th === header) {
                        thArrow.textContent = sortOrder === 'asc' ? ' ▲' : ' ▼';
                        th.setAttribute('aria-sort', sortOrder === 'asc' ? 'ascending' : 'descending');
                    } else {
                        thArrow.textContent = '';
                        th.setAttribute('aria-sort', 'none');
                    }
                });
                
                currentSort = { columnIndex: colIndex, order: sortOrder };
            });
        });
    }
});
