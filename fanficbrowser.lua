local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local DownloadedFanfics = require("downloaded_fanfics")
local InfoMessage = require("ui/widget/infomessage")
local Config = require("fanfic_config")
local MenuStack = require("menu_stack")
local _ = require("gettext")
local util = require("util")
local FFIUtil = require("ffi/util")
local AO3Manager = require("AO3_manager")
local T = FFIUtil.template

local KeyValuePage = require("ui/widget/keyvaluepage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
local InputContainer = require("ui/widget/container/inputcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local Font = require("ui/font")
local Device = require("device")
local Screen = Device.screen
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local Blitbuffer = require("ffi/blitbuffer")
local FanficReader = require("fanfic_reader")

local FanficBrowser = {
    ui = nil,
    showAuthorInfoCallback = nil,
    searchByTagCallback = nil,
}

-- Split a comma-separated string into a table, or return the table as-is.
-- Needed because AO3 API sometimes returns strings instead of arrays.
local function normalizeField(field)
    if type(field) == "string" then
        local result = {}
        for item in string.gmatch(field, "([^,]+)") do
            table.insert(result, util.trim(item))
        end
        return result
    elseif type(field) == "table" then
        return field
    else
        return {}
    end
end

-- Format a number with comma separators for readability (e.g. 45231 -> "45,231").
-- Strips any existing commas first because AO3 sometimes returns pre-formatted strings.
local function formatNumber(n)
    if not n then return "0" end
    local s = tostring(n):gsub(",", "")
    local result = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if result:sub(1, 1) == "," then
        result = result:sub(2)
    end
    return result
end

-- Card page widget extending KeyValuePage. Inherits the nav bar, title bar,
-- gesture handling, keyboard support, and screen refresh logic. Only the
-- content area rendering is customized to show one fanfic card per page.
local FanficCardPage = KeyValuePage:extend{}

function FanficCardPage:init()
    -- Build a dummy kv_pairs array so the parent's pagination math works.
    -- Each entry maps to one fanfic; we override _populateItems to render
    -- card content instead of KeyValueItem rows.
    self.kv_pairs = {}
    for i = 1, #self.fanfics do
        table.insert(self.kv_pairs, {tostring(i), ""})
    end

    -- Prevent the parent's _populateItems call during init from doing real
    -- work, since items_per_page and pages haven't been corrected yet.
    self._card_init_done = false
    KeyValuePage.init(self)
    self._card_init_done = true

    -- One fanfic per page instead of the parent's multi-row layout.
    self.items_per_page = 1
    self.pages = #self.fanfics

    -- The parent init computes available_height as a local. Recompute it
    -- here so buildCard knows how much vertical space the content area has.
    self.content_height = self.dimen.h
        - self.title_bar:getHeight()
        - Size.span.vertical_large
        - self.page_info:getSize().h
        - 2 * Size.line.thick

    self:_populateItems()
end

function FanficCardPage:_populateItems()
    if not self._card_init_done then return end

    -- Fetch the next AO3 page when arriving at the last loaded fanfic, but not if we have already loaded all items from the search
    if self.show_page == self.pages and self.fetchNextPage and self.show_page ~= self.totalFanfics then
        local new_fics = self.fetchNextPage()
        if new_fics and #new_fics > 0 then
            for _, fic in ipairs(new_fics) do
                table.insert(self.fanfics, fic)
                table.insert(self.kv_pairs, {tostring(#self.fanfics), ""})
            end
            self.pages = #self.fanfics
        end
    end

    self.layout = {}
    self.page_info:resetLayout()
    self.return_button:resetLayout()
    self.main_content:clear()

    local fanfic = self.fanfics[self.show_page]
    if fanfic then
        local card = self:buildCard(fanfic)
        table.insert(self.main_content, card)
    end

    -- Nav bar update - identical to KeyValuePage._populateItems
    if self.pages > 1 then
        self.page_info_text:setText(T(_("Work %1 of %2"), self.show_page, self.pages))
        self.page_info_text:enable()

        self.page_info_left_chev:show()
        self.page_info_right_chev:show()
        self.page_info_first_chev:show()
        self.page_info_last_chev:show()

        self.page_info_left_chev:enableDisable(self.show_page > 1)
        self.page_info_right_chev:enableDisable(self.show_page < self.pages)
        self.page_info_first_chev:enableDisable(self.show_page > 1)
        self.page_info_last_chev:enableDisable(self.show_page < self.pages)
    else
        if self.pages < 1 then
            self.page_info_text:setText(_("No items"))
        end
        
        self.page_info_text:disableWithoutDimming()
        self.page_info_left_chev:hide()
        self.page_info_right_chev:hide()
        self.page_info_first_chev:hide()
        self.page_info_last_chev:hide()
    end

    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

-- Wrap a widget in an InputContainer that fires callback on tap.
-- The widget must already have a size so the gesture range can be set.
function FanficCardPage:makeTappable(widget, callback)
    local size = widget:getSize()
    local container = InputContainer:new{
        dimen = Geom:new{ w = size.w, h = size.h },
        widget,
    }
    if Device:isTouchDevice() then
        container.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = container.dimen,
                },
            },
        }
        container.onTap = function()
            callback()
            return true
        end
    end
    return container
end

-- Show a disambiguation dialog listing multiple values. Tapping a value
-- triggers the given callback with that value. Used for authors, fandoms,
-- relationships, and characters.
function FanficCardPage:showPickerDialog(title, values, callback)
    local buttons = {}
    for _, value in ipairs(values) do
        table.insert(buttons, {{
            text = value,
            callback = function()
                UIManager:close(self._picker_dialog)
                callback(value)
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("Close"),
        callback = function()
            UIManager:close(self._picker_dialog)
        end,
    }})
    self._picker_dialog = ButtonDialog:new{
        title = title,
        buttons = buttons,
    }
    UIManager:show(self._picker_dialog)
end

--- Build the full card widget for a single fanfic.
-- Returns a VerticalGroup that fits within the content area established
-- by the parent KeyValuePage layout.
function FanficCardPage:buildCard(fanfic)
    local content_width = self.item_width

    local title_face = Font:getFace("tfont", 24)
    local body_face = Font:getFace("cfont", 20)
    local stats_face = Font:getFace("ffont", 18)

    -- Normalize fields that may arrive as comma-separated strings
    fanfic.fandoms = normalizeField(fanfic.fandoms)
    fanfic.warnings = normalizeField(fanfic.warnings)
    fanfic.relationships = normalizeField(fanfic.relationships)
    fanfic.characters = normalizeField(fanfic.characters)
    fanfic.tags = normalizeField(fanfic.tags)

    local used_height = 0
    local elements = {}

    local function addElement(widget)
        table.insert(elements, widget)
        used_height = used_height + widget:getSize().h
    end

    local function addSpacing(height)
        local span = VerticalSpan:new{ width = height or Size.padding.default }
        addElement(span)
    end

    -- Truncate text with ellipsis if it would overflow max_height when
    -- rendered. Uses actual TextBoxWidget measurement so DPI scaling
    -- cannot cause silent clipping. Binary searches for the longest
    -- substring that fits so the ellipsis appears near the right edge.
    local function truncateToFit(text, face, max_height)
        local probe = TextBoxWidget:new{ text = text, face = face, width = content_width }
        local actual_height = probe:getSize().h
        probe:free()
        if actual_height <= max_height then
            return text
        end
        -- Start from a proportional estimate, then binary search upward
        -- to find the longest substring that still fits with "..." appended.
        local lo = math.max(1, math.floor(#text * (max_height / actual_height)))
        local hi = #text
        while lo < hi do
            local mid = math.ceil((lo + hi) / 2)
            probe = TextBoxWidget:new{
                text = text:sub(1, mid) .. "...",
                face = face,
                width = content_width,
            }
            local fits = probe:getSize().h <= max_height
            probe:free()
            if fits then
                lo = mid
            else
                hi = mid - 1
            end
        end
        return text:sub(1, lo) .. "..."
    end

    -- Build a tappable single-line text element. If the full text was
    -- truncated, tapping expands it in a TextViewer popup.
    local function addTappableField(display_text, full_text, face, height, tap_callback)
        local widget = TextBoxWidget:new{
            text = display_text,
            face = face,
            width = content_width,
            height = height,
        }
        if tap_callback then
            addElement(self:makeTappable(widget, tap_callback))
        elseif display_text ~= full_text then
            -- Text was truncated, tap to expand in a popup
            addElement(self:makeTappable(widget, function()
                UIManager:show(TextViewer:new{
                    title = _("Full text"),
                    text = full_text,
                    width = content_width,
                })
            end))
        else
            addElement(widget)
        end
    end

    -- == TITLE ==
    local title_text
    if fanfic.is_deleted then
        title_text = "DELETED WORK"
    else
        title_text = fanfic.title or "Untitled"
        if fanfic.is_restricted then
            title_text = "🔒 " .. title_text
        end
        if DownloadedFanfics.checkIfStored(fanfic.id) then
            title_text = "✓ " .. title_text
        end
    end
    local title_line_height = TextBoxWidget:new{
        text = "X",
        face = title_face,
        width = content_width,
        bold = true,
    }:getSize().h

    local title_display = truncateToFit(title_text, title_face, title_line_height)

    -- Title tap: download dialog (new fic) or update/open (already downloaded).
    local title_widget = TextBoxWidget:new{
        text = title_display,
        face = title_face,
        width = content_width,
        height = title_line_height,
        bold = true,
    }
    if not fanfic.is_deleted then
        addElement(self:makeTappable(title_widget, function()
            self:onTitleTap(fanfic)
        end))
    else
        addElement(title_widget)
    end

    -- == AUTHOR LINE ==
    local author_text = "by " .. (fanfic.author or "Anonymous")
    if fanfic.gifted_to then
        author_text = author_text .. " (Gifted to: " .. fanfic.gifted_to .. ")"
    end
    local author_widget = TextBoxWidget:new{
        text = author_text,
        face = stats_face,
        width = content_width,
    }
    -- Tap to show author profile. If multiple authors, shows a picker.
    if fanfic.author then
        addElement(self:makeTappable(author_widget, function()
            self:onAuthorTap(fanfic)
        end))
    else
        addElement(author_widget)
    end

    addSpacing(Size.padding.small)
    addElement(LineWidget:new{
        dimen = Geom:new{ w = content_width, h = Size.line.medium },
        background = Blitbuffer.COLOR_DARK_GRAY,
    })
    addSpacing(Size.padding.small)

    if not fanfic.is_deleted then

        local document_parts = {}
        if fanfic.wordcount then
            table.insert(document_parts, "Words: " .. formatNumber(fanfic.wordcount))
        end
        if fanfic.chapters then
            table.insert(document_parts, fanfic.chapters .. " Chapters")
        end
        table.insert(document_parts, fanfic.iswip or "Unknown")
        addElement(TextBoxWidget:new{
            text = table.concat(document_parts, " | "),
            face = stats_face,
            width = content_width,
        })

        -- == STATS ==
        local stats_parts = {}
        if fanfic.rating then
            local short_ratings = {
                ["Not Rated"] = "None",
                ["General Audiences"] = "General",
                ["Teen And Up Audiences"] = "Teen",
                ["Mature"] = "Mature",
                ["Explicit"] = "Explicit",
            }
            table.insert(stats_parts, "Rating: " .. (short_ratings[fanfic.rating] or fanfic.rating))
        end
        if fanfic.language then
            table.insert(stats_parts, fanfic.language)
        end
        if fanfic.published then
            table.insert(stats_parts, "\u{f093} " .. fanfic.published)
        end
        if fanfic.updated then
            table.insert(stats_parts, "\u{f040} " .. fanfic.updated)
        end
        addElement(TextBoxWidget:new{
            text = table.concat(stats_parts, " | "),
            face = stats_face,
            width = content_width,
        })

        local engagement_parts = {}
        if fanfic.comments then table.insert(engagement_parts, "\u{f075} " .. formatNumber(fanfic.comments)) end
        if fanfic.kudos then table.insert(engagement_parts, "♥ " .. formatNumber(fanfic.kudos)) end

        if fanfic.bookmarks then table.insert(engagement_parts, "\u{f02e} " .. formatNumber(fanfic.bookmarks)) end
        if fanfic.hits then table.insert(engagement_parts, "\u{f080}  " .. formatNumber(fanfic.hits)) end
        
        if #engagement_parts > 0 then
            addElement(TextBoxWidget:new{
                text = table.concat(engagement_parts, " | "),
                face = stats_face,
                width = content_width,
            })
        end

        local saved_parts = {}
        if fanfic.bookmarkID then table.insert(saved_parts, fanfic.bookmarkID and "Bookmarked: " .. (("Yes (" .. tostring(fanfic.bookmarkID) ..")") or "No")) end
        if fanfic.markedForLater then table.insert(saved_parts, fanfic.markedForLater and "Marked for Later: " .. ("Yes" or "No")) end
        if fanfic.subscriptionID then table.insert(saved_parts, fanfic.subscriptionID and "Subscribed: " .. (("Yes (" .. fanfic.subscriptionID ..")") or "No")) end

        if #saved_parts > 0 then
            addElement(TextBoxWidget:new{
                text = table.concat(saved_parts, " | "),
                face = stats_face,
                width = content_width,
            })
        end

        -- == SEPARATOR ==
        addSpacing(Size.padding.small)
        addElement(LineWidget:new{
            dimen = Geom:new{ w = content_width, h = Size.line.medium },
            background = Blitbuffer.COLOR_DARK_GRAY,
        })
        addSpacing(Size.padding.small)

        -- == TAG SECTIONS ==
        -- Measure one line height for truncation constraints.
        local tag_line_height = TextBoxWidget:new{
            text = "X",
            face = stats_face,
            width = content_width,
        }:getSize().h

        -- Fandom - tap to search by fandom tag
        if #fanfic.fandoms > 0 then 
            local fandom_full = "Fandom: " .. table.concat(fanfic.fandoms, ", ")
            local fandom_display = truncateToFit(fandom_full, stats_face, tag_line_height)
            local fandom_callback = nil
            if #fanfic.fandoms > 0 and self.searchByTagCallback then
                fandom_callback = function()
                    self:onTagFieldTap(fanfic.fandoms, "Fandom", fandom_full)
                end
            end
            addTappableField(fandom_display, fandom_full, stats_face, tag_line_height, fandom_callback)
        end

        -- Warnings - display only, tap to expand if truncated
        if #fanfic.warnings > 0 then
            local warnings_full = "Warnings: " .. table.concat(fanfic.warnings, ", ")
            local warnings_display = truncateToFit(warnings_full, stats_face, tag_line_height)
            addTappableField(warnings_display, warnings_full, stats_face, tag_line_height)
        end

        -- Relationships - tap to search by relationship tag
        if fanfic.category or #fanfic.relationships > 0 then
            local rel_full = "Relationships: "
            if fanfic.category and fanfic.category ~= "" then
                rel_full = rel_full .. "(" .. fanfic.category .. ") "
            end
            rel_full = rel_full .. (#fanfic.relationships > 0 and table.concat(fanfic.relationships, ", ") or "None listed")
            local rel_display = truncateToFit(rel_full, stats_face, tag_line_height)
            local rel_callback = nil
            if #fanfic.relationships > 0 and self.searchByTagCallback then
                rel_callback = function()
                    self:onTagFieldTap(fanfic.relationships, "Relationship", rel_full)
                end
            end
            addTappableField(rel_display, rel_full, stats_face, tag_line_height, rel_callback)
        end 

        -- Characters - tap to search by character tag
        if #fanfic.characters > 0 then
            local char_full = "Characters: " .. table.concat(fanfic.characters, ", ")
            local char_display = truncateToFit(char_full, stats_face, tag_line_height)
            local char_callback = nil
            if self.searchByTagCallback then
                char_callback = function()
                    self:onTagFieldTap(fanfic.characters, "Character", char_full)
                end
            end
            addTappableField(char_display, char_full, stats_face, tag_line_height, char_callback)
        end

        -- Tags - tap to expand if truncated, no search
        if #fanfic.tags > 0 then
            local tags_full = "Tags: " .. table.concat(fanfic.tags, ", ")
            local tags_display = truncateToFit(tags_full, stats_face, tag_line_height)
            addTappableField(tags_display, tags_full, stats_face, tag_line_height)
        end

        -- Series
        if fanfic.series and #fanfic.series > 0 then
            local parts = {}
            for _, s in ipairs(fanfic.series) do
                table.insert(parts, ("Part %s of %s"):format(s.part, s.title))
            end
            local series_full = "Series: " .. table.concat(parts, ", ")
            local series_display = truncateToFit(series_full, stats_face, tag_line_height)
            local series_callback = nil
            if self.searchByTagCallback then
                series_callback = function()
                    self:onSeriesFieldTap(fanfic.series, series_full)
                end
            end
            addTappableField(series_display, series_full, stats_face, tag_line_height,series_callback)
        end

        -- == SEPARATOR before summary ==
        addSpacing(Size.padding.small)
        addElement(LineWidget:new{
            dimen = Geom:new{ w = content_width, h = Size.line.medium },
            background = Blitbuffer.COLOR_DARK_GRAY,
        })
        addSpacing(Size.padding.small)
    end

    -- == SUMMARY ==
    -- Gets all remaining vertical space after the elements above.
    local available_for_summary = self.content_height - used_height
    if available_for_summary < Screen:scaleBySize(60) then
        available_for_summary = Screen:scaleBySize(60)
    end

    local raw_summary = fanfic.summary or "No summary available"
    local summary_display = truncateToFit(raw_summary, body_face, available_for_summary)

    -- Tap to expand in a popup if the summary was truncated
    addTappableField(summary_display, raw_summary, body_face, available_for_summary)

    local card_content = VerticalGroup:new{ align = "left" }
    for _, elem in ipairs(elements) do
        table.insert(card_content, elem)
    end

    return card_content
end

-- Title tap: show download dialog for new fics, or update/open for downloaded ones.
function FanficCardPage:onTitleTap(fanfic)
    if fanfic.id == nil then
        return
    end
    local downloaded = DownloadedFanfics.checkIfStored(fanfic.id)
    if downloaded then
        local dialog
        dialog = ButtonDialog:new{
            title = _("Fanfic is already downloaded, what would you like to do?"),
            buttons = {
                {
                    {
                        text = _("Update"),
                        callback = function()
                            UIManager:close(dialog)
                            UIManager:scheduleIn(1, function()
                                AO3Manager:UpdateFanfic(downloaded)
                            end)
                            UIManager:show(InfoMessage:new{
                                text = _("Downloading work may take some time."),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("Open"),
                        callback = function()
                            UIManager:close(dialog)
                            FanficReader:show({
                                fanfic_path = downloaded.path,
                                current_fanfic = downloaded,
                                chapter_opening_at = nil,
                            })
                        end,
                    },
                    {
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(dialog)
                        end,
                    },
                },
            },
        }
        UIManager:show(dialog)
    else
        if Config:readSetting("show_adult_warning")
            and (fanfic.rating == "Explicit" or fanfic.rating == "Mature" or fanfic.rating == "Not Rated")
        then
            FanficBrowser:showAdultWarningDialog(fanfic)
        else
            FanficBrowser:showDownloadDialog(fanfic)
        end
    end
end

-- Author tap: show author profile. If multiple authors or a giftee exists,
-- show a picker so the user can choose which profile to view.
function FanficCardPage:onAuthorTap(fanfic)
    local people = {}
    if fanfic.author then
        for author in string.gmatch(fanfic.author, "([^,]+)") do
            table.insert(people, util.trim(author))
        end
    end
    if fanfic.gifted_to then
        for giftee in string.gmatch(fanfic.gifted_to, "([^,]+)") do
            table.insert(people, util.trim(giftee) .. " (Giftee)")
        end
    end

    if #people == 1 then
        self.showAuthorInfoCallback(people[1])
    elseif #people > 1 then
        self:showPickerDialog(
            T("Work %1: %2", string.find(fanfic.author, ",") and "authors" or "author", fanfic.author),
            people,
            function(selected)
                -- Strip " (Giftee)" suffix before looking up
                local name = selected:gsub(" %(Giftee%)$", "")
                self.showAuthorInfoCallback(name)
            end
        )
    end
end

-- Tag field tap: if one value, search directly. If multiple, show a picker.
-- The picker also offers an "expand" option to view the full text.
function FanficCardPage:onTagFieldTap(values, category, full_text)
    if #values == 1 then
        self.searchByTagCallback(values[1])
    elseif #values > 1 then
        -- Build buttons: each value searches, plus an expand option
        local buttons = {}
        for _, value in ipairs(values) do
            table.insert(buttons, {{
                text = value,
                callback = function()
                    UIManager:close(self._picker_dialog)
                    self.searchByTagCallback(value)
                end,
            }})
        end
        table.insert(buttons, {{
            text = _("View all"),
            callback = function()
                UIManager:close(self._picker_dialog)
                UIManager:show(TextViewer:new{
                    title = category,
                    text = full_text,
                })
            end,
        }})
        table.insert(buttons, {{
            text = _("Close"),
            callback = function()
                UIManager:close(self._picker_dialog)
            end,
        }})
        self._picker_dialog = ButtonDialog:new{
            title = T("Search by %1", category),
            buttons = buttons,
        }
        UIManager:show(self._picker_dialog)
    end
end

-- Tag field tap: if one value, search directly. If multiple, show a picker.
-- The picker also offers an "expand" option to view the full text.
function FanficCardPage:onSeriesFieldTap(values, full_text)
    if #values == 1 then
        self.openSeriesCallback(values[1])
    elseif #values > 1 then
        -- Build buttons: each value searches, plus an expand option
        local buttons = {}
        for _, value in ipairs(values) do
            table.insert(buttons, {{
                text = value.title,
                callback = function()
                    UIManager:close(self._picker_dialog)
                    self.openSeriesCallback(value)
                end,
            }})
        end
        table.insert(buttons, {{
            text = _("View all"),
            callback = function()
                UIManager:close(self._picker_dialog)
                UIManager:show(TextViewer:new{
                    title = "Series",
                    text = full_text,
                })
            end,
        }})
        table.insert(buttons, {{
            text = _("Close"),
            callback = function()
                UIManager:close(self._picker_dialog)
            end,
        }})
        self._picker_dialog = ButtonDialog:new{
            title = "Open series",
            buttons = buttons,
        }
        UIManager:show(self._picker_dialog)
    end
end

function FanficBrowser:showDownloadDialog(fanfic)
    local confirmDialog
    confirmDialog = ButtonDialog:new({
        title = T("Would you like to download the work: %1 by %2?", fanfic.title, fanfic.author),
        buttons = {
            {
                {
                    text = "No",
                    callback = function()
                        UIManager:close(confirmDialog)
                    end,
                },
                {
                    text = "Yes",
                    callback = function()
                        UIManager:scheduleIn(1, function()
                            AO3Manager:DownloadFanfic(fanfic.id)
                        end)
                        UIManager:show(InfoMessage:new({
                            text = _("Downloading work may take some time."),
                            timeout = 1,
                        }))
                        UIManager:close(confirmDialog)
                    end,
                },
            },
        },
    })
    UIManager:show(confirmDialog)
end

function FanficBrowser:showAdultWarningDialog(fanfic)
    local warningDialog
    warningDialog = ButtonDialog:new({
        title = "This work could have adult content. If you continue, you have agreed that you are willing to see such content",
        buttons = {
            {
                {
                    text = "Cancel",
                    callback = function()
                        UIManager:close(warningDialog)
                    end,
                },
                {
                    text = "Continue",
                    callback = function()
                        UIManager:close(warningDialog)
                        self:showDownloadDialog(fanfic)
                    end,
                },
            },
        },
    })
    UIManager:show(warningDialog)
end

--- Main entry point - called by main.lua and fanfic_menu.lua.
-- searchByTagCallback is optional; when provided, fandom/relationship/character
-- fields become tappable to trigger a tag search.
function FanficBrowser:show(ficResults, fetchNextPage, showAuthorInfoCallback, searchByTagCallback, openSeriesCallback)

    -- Remove the total field so it does not get treated as a fanfic entry.
    local totalFanfics = -1
    
    if ficResults.total then
        totalFanfics = ficResults.total
        ficResults.total = nil
    end
    

    local title = "AO3 Search Results"
    if ficResults.searchType then
        title = ficResults.searchType
        ficResults.searchType = nil
    end

    title = title .. (totalFanfics > -1 and (" | " .. ((title == "AO3 Series") and (totalFanfics-1 .. " Works") or (totalFanfics .. " Found"))) or "")

    local browse_window = FanficCardPage:new{
        title = title,
        fanfics = ficResults,
        totalFanfics = totalFanfics,
        fetchNextPage = fetchNextPage,
        -- Pass callbacks through so the card page can trigger actions
        showAuthorInfoCallback = showAuthorInfoCallback,
        searchByTagCallback = searchByTagCallback,
        openSeriesCallback = openSeriesCallback,
    }

    -- Assigned after construction so the closure captures the populated
    -- local rather than a nil upvalue from inside the constructor table.
    browse_window.close_callback = function()
        MenuStack.menu_stack[browse_window] = nil
    end

    MenuStack.menu_stack[browse_window] = true
    UIManager:show(browse_window)
end

return FanficBrowser
