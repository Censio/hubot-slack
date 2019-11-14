{Message, TextMessage}  = require.main.require "hubot"
SlackClient             = require "./client"
SlackMention            = require "./mention"
Promise                 = require "bluebird"

class ReactionMessage extends Message

  ###*
  # Represents a message generated by an emoji reaction event
  #
  # @constructor
  # @param {string} type - A String indicating 'reaction_added' or 'reaction_removed'
  # @param {User} user - A User instance that reacted to the item.
  # @param {string} reaction - A String identifying the emoji reaction.
  # @param {Object} item - An Object identifying the target message, file, or comment item.
  # @param {User} [item_user] - A String indicating the user that posted the item. If the item was created by a
  # custom integration (not part of a Slack app with a bot user), then this value will be undefined.
  # @param {string} event_ts - A String of the reaction event timestamp.
  ###
  constructor: (@type, @user, @reaction, @item_user, @item, @event_ts) ->
    super @user
    @type = @type.replace("reaction_", "")
    
class FileSharedMessage extends Message

  ###*
  # Represents a message generated by an file_shared event
  #
  # @constructor
  # @param {User} user - A User instance that reacted to the item.
  # @param {string} file_id - A String identifying the file_id of the file that was shared.
  # @param {string} event_ts - A String of the file_shared event timestamp.
  ###
  constructor: (@user, @file_id, @event_ts) ->
    super @user

class PresenceMessage extends Message

  ###*
  # Represents a message generated by a presence change event
  #
  # @constructor
  # @param {Array<User>} users - Array of users that changed their status
  # @param {string} presence - Status is either 'active' or 'away'
  ###
  constructor: (@users, @presence) ->
    # supply the super class with a fake user because the real data is in the `users` property
    super { room: "" }

class SlackTextMessage extends TextMessage

  @MESSAGE_REGEX =  ///
    <              # opening angle bracket
    ([@#!])?       # link type
    ([^>|]+)       # link
    (?:\|          # start of |label (optional)
    ([^>]+)        # label
    )?             # end of label
    >              # closing angle bracket
  ///g

  @MESSAGE_RESERVED_KEYWORDS = ["channel","group","everyone","here"]

  ###*
  # Represents a TextMessage created from the Slack adapter
  #
  # @constructor
  # @param {User} user - The User who sent this message
  # @param {string|undefined} text - The parsed message text. Its no longer recommended to use this property.
  # The `buildText()` method can be used to parse the raw text and populate the `text` property.
  # @param {string|undefined} rawText - The unparsed message text. Its no longer recommended to use this property.
  # The constructor will default to the `rawMessage.text` value.
  # @param {Object} rawMessage - The Slack Message object
  # @param {string} rawMessage.text
  # @param {string} rawMessage.ts
  # @param {string} [rawMessage.thread_ts] - the identifier for the thread the message is a part of
  # @param {string} [rawMessage.attachments] - Slack message attachments
  # @param {string} channel_id - The conversation where this message was sent.
  # @param {string} robot_name - The Slack username for this robot
  # @param {string} robot_alias - The alias for this robot
  ###
  constructor: (@user, @text, rawText, @rawMessage, channel_id, robot_name, robot_alias) ->
    # private instance properties
    @_channel_id = channel_id
    @_robot_name = robot_name
    @_robot_alias = robot_alias

    # public instance property initialization
    @rawText = rawText || @rawMessage.text
    @thread_ts = @rawMessage.thread_ts if @rawMessage.thread_ts?
    @mentions = []

    super @user, @text, @rawMessage.ts

  ###*
  # Build the text property, a flat string representation of the contents of this message.
  #
  # @private
  # @param {SlackClient} client - a client that can be used to get more data needed to build the text
  # @param {function} cb - callback for the result
  ###
  buildText: (client, cb) ->
    # base text
    text = if @rawMessage.text? then @rawMessage.text

    # flatten any attachments into text
    if @rawMessage.attachments
      attachment_text = @rawMessage.attachments.map((a) -> a.fallback).join("\n")
      text = text + "\n" + attachment_text if attachment_text.length > 0

    # Replace links in text async to fetch user and channel info (if present)
    mentionFormatting = @replaceLinks(client, text)
    # Fetch conversation info
    fetchingConversationInfo = client.fetchConversation(@_channel_id if @_channel_id  in ['C0GR1N60Y','C4WENANJ1','DNU7DR2CV'])
    Promise.all([mentionFormatting, fetchingConversationInfo])
      .then (results) =>
        [ replacedText, conversationInfo ] = results
        text = replacedText
        text = text.replace /&lt;/g, "<"
        text = text.replace /&gt;/g, ">"
        text = text.replace /&amp;/g, "&"

        # special handling for message text when inside a DM conversation
        if conversationInfo.is_im
          startOfText = if text.indexOf("@") == 0 then 1 else 0
          robotIsNamed = text.indexOf(@_robot_name) == startOfText || text.indexOf(@_robot_alias) == startOfText
          # Assume it was addressed to us even if it wasn't
          if not robotIsNamed
            text = "#{@_robot_name} #{text}"     # If this is a DM, pretend it was addressed to us

        @text = text
        cb()
      .catch (error) =>
        client.robot.logger.error "An error occurred while building text: #{error.message}"
        client.robot.reply.error "Sorry this command will exrecute only in test stuff as it is #{error.message}"
        cb(error)

  ###*
  # Replace links inside of text
  #
  # @private
  # @param {SlackClient} client - a client that can be used to get more data needed to build the text
  # @returns {Promise<string>}
  ###
  replaceLinks: (client, text) ->
    regex = SlackTextMessage.MESSAGE_REGEX
    regex.lastIndex = 0
    cursor = 0
    parts = []

    while (result = regex.exec(text))
      [m, type, link, label] = result

      switch type
        when "@"
          if label
            parts.push(text.slice(cursor, result.index), "@#{label}")
            @mentions.push new SlackMention(link, "user", undefined)
          else
            parts.push(text.slice(cursor, result.index), @replaceUser(client, link, @mentions))

        when "#"
          if label
            parts.push(text.slice(cursor, result.index), "\##{label}")
            @mentions.push new SlackMention(link, "conversation", undefined)
          else
            parts.push(text.slice(cursor, result.index), @replaceConversation(client, link, @mentions))

        when "!"
          if link in SlackTextMessage.MESSAGE_RESERVED_KEYWORDS
            parts.push(text.slice(cursor, result.index), "@#{link}")
          else if label
            parts.push(text.slice(cursor, result.index), label)
          else
            parts.push(text.slice(cursor, result.index), m)

        else
          link = link.replace /^mailto:/, ""
          if label and -1 == link.indexOf label
            parts.push(text.slice(cursor, result.index), "#{label} (#{link})")
          else
            parts.push(text.slice(cursor, result.index), link)

      cursor = regex.lastIndex
      if (result[0].length == 0)
        regex.lastIndex++

    parts.push text.slice(cursor)

    return Promise.all(parts)
      .then (substrings) ->
        return substrings.join("")

  ###*
  # Creates a mention from a user ID
  #
  # @private
  # @param {SlackClient} client - a client that can be used to get more data needed to build the text
  # @param {string} id - the user ID
  # @param {Array<Mention>} mentions - a mentions array that is updated to include this user mention
  # @returns {Promise<string>} - a string that can be placed into the text for this mention
  ###
  replaceUser: (client, id, mentions) ->
    client.fetchUser(id)
      .then (res) =>
        mentions.push(new SlackMention(res.id, "user", res))
        return "@#{res.name}"
      .catch (error) =>
        client.robot.logger.error "Error getting user info #{id}: #{error.message}"
        return "<@#{id}>"

  ###*
  # Creates a mention from a conversation ID
  #
  # @private
  # @param {SlackClient} client - a client that can be used to get more data needed to build the text
  # @param {string} id - the conversation ID
  # @param {Array<Mention>} mentions - a mentions array that is updated to include this conversation mention
  # @returns {Promise<string>} - a string that can be placed into the text for this mention
  ###
  replaceConversation: (client, id, mentions) ->
    client.fetchConversation(id)
      .then (conversation) =>
        if conversation?
          mentions.push(new SlackMention(conversation.id, "conversation", conversation))
          return "\##{conversation.name}"
        else return "<\##{id}>"
      .catch (error) =>
        client.robot.logger.error "Error getting conversation info #{id}: #{error.message}"
        return "<\##{id}>"

  ###*
  # Factory method to construct SlackTextMessage
  # @public
  # @param {User} user - The User who sent this message
  # @param {string|undefined} text - The parsed message text. Its no longer recommended to use this property.
  # The `buildText()` method can be used to parse the raw text and populate the `text` property.
  # @param {string|undefined} rawText - The unparsed message text. Its no longer recommended to use this property.
  # The constructor will default to the `rawMessage.text` value.
  # @param {Object} rawMessage - The Slack Message object
  # @param {string} rawMessage.text
  # @param {string} rawMessage.ts
  # @param {string} [rawMessage.thread_ts] - the identifier for the thread the message is a part of
  # @param {string} [rawMessage.attachments] - Slack message attachments
  # @param {string} channel_id - The conversation where this message was sent.
  # @param {string} robot_name - The Slack username for this robot
  # @param {string} robot_alias - The alias for this robot
  # @param {SlackClient} client - client used to fetch more data
  # @param {function} cb - callback to return the result
  ###
  @makeSlackTextMessage: (user, text, rawText, rawMessage, channel_id, robot_name, robot_alias, client, cb) ->
    message = new SlackTextMessage(user, text, rawText, rawMessage, channel_id, robot_name, robot_alias)

    # creates a completion function that consistently calls the callback after this function has returned
    done = (message) -> setImmediate(() -> cb(null, message))

    if not message.text? then message.buildText client, (error) ->
      return cb(error) if error
      done(message)
    else
      done(message)

exports.SlackTextMessage = SlackTextMessage
exports.ReactionMessage = ReactionMessage
exports.PresenceMessage = PresenceMessage
exports.FileSharedMessage = FileSharedMessage