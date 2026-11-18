local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local FanficBrowser = require("fanficbrowser")
local Config = require("fanfic_config")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local AO3Manager = require("AO3_manager")
local CustomFilterEditor = require("custom_filter_editor")

local CustomFilterMenu = {}

function CustomFilterMenu:show(menuWidget)
    self.menuWidget = menuWidget

    self.menuWidget:GoDownInMenu("Select filter", self:refreshMainMenu())
end

function CustomFilterMenu:refreshMainMenu()
    local menuOptions = {
        {
            text = "+ Create new filter",
            callback = function()
                CustomFilterEditor:show({}, function (filter) self:executeSearch(filter) end, self.refreshMainMenu, self.menuWidget)
            end,
        },
    }
    local filters = Config:readSetting("saved_filters", {})
    if #filters > 0 then
        table.insert(menuOptions, {
            text = "Saved filters:",
        })
    end
    for __, filter in pairs(filters) do
        table.insert(menuOptions, {
            text = "     " .. filter.title,
            callback = function()
                local optionsDialog
                optionsDialog = ButtonDialog:new({
                    buttons = {
                        {
                            {
                                text = "Search using filter",
                                callback = function()
                                    self:executeSearch(filter)
                                    UIManager:close(optionsDialog)
                                end,
                            },
                        },
                        {
                            {
                                text = "Edit filter",
                                callback = function()
                                    CustomFilterEditor:show(filter, function(filter) self:executeSearch(filter) end, self.refreshMainMenu, self.menuWidget)
                                    UIManager:close(optionsDialog)
                                end,
                            },
                        },
                        {
                            {
                                text = "Delete filter",
                                callback = function()
                                    local filters = Config:readSetting("saved_filters")
                                    filters[filter.title] = nil
                                    Config:saveSetting("saved_filters", filters)
                                    self.menuWidget.item_table = self:refreshMainMenu()
                                    self.menuWidget:updateItems()
                                    UIManager:close(optionsDialog)
                                end,
                            },
                        },
                        {
                            {
                                text = "Cancel",
                                callback = function()
                                    UIManager:close(optionsDialog)
                                end,
                            },
                        },
                    },
                })
                UIManager:show(optionsDialog)
            end,
        })
    end
    return menuOptions
end

-- Execute the search with the crafted filter
function CustomFilterMenu:executeSearch(filter)
    if not filter.main_tag then
        UIManager:show(InfoMessage:new({
            text = _("Main tag is required"),
        }))
        return
    end
    UIManager:scheduleIn(1, function()
        filter.type = "works"
        local status, searchResult = AO3Manager:executeSearch(filter)

        if not status then
            UIManager:show(InfoMessage:new({
                text = _("Failed to fetch results for the custom filter."),
                timeout = 2,
            }))
            return
        end

        -- Show the results in the FanficBrowser
        FanficBrowser:show(searchResult)
    end)

    UIManager:show(InfoMessage:new({
        text = _("Searching with custom filter..."),
        timeout = 1,
    }))
end

return CustomFilterMenu
