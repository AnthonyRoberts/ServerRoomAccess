/*
Anthony Roberts
February 2011

Don't forget to disconnect the ID-20 connection to the Arduino Rx pin before uploading (or you'll get errors during the upload)

I ran into memory problems as the program expanded (showed -188 at one point) so most of the Serial.print stuff has been removed to save space. You don't get warned 
that there's no memory, it just behaves wierd. The setup() function includes a memory status (to the Serial Monitor) to assist.

ID-20 RFID MODULE
Connect Pin 9 (D0) from the ID-20 to Rx (Pin 0) in the Arduino
The ID-20 returns 16 bytes. The first byte is 0x02 which means a 12 byte RFID sequence is about to follow
After the 12 bytes RFID, there's a 0x0D, 0x0A and 0x03. I'm just flushing the final characters, but if you want more thorough check, you could ensure the final 
three bytes match these. 

ETHERNET SHIELD
Uses pins 11, 12 and 13. Pin 10 is used to select the Ethernet and Pin 4 the SD Card (you can't have both active at the same time). 
*/


#include <EEPROM.h>    // We're going to store RFID ID tags in EEPROM 
#include <SdFat.h>     // microSD card on the Ethernet shield
#include <SdFatUtil.h> // Use functions to print strings from flash memory
#include <WProgram.h>  // Used by the 1307 Real-Time Clock 
#include <Wire.h>      // Used by the 1307 Real-Time Clock
#include <DS1307.h>    // Used by the 1307 Real-Time Clock
#include <Ethernet.h>  // Ethernet Shield
#include <SPI.h>       // Required to communicate with Ethernet Shield
#include <UDP.h>       // UDP for receiving messages from remote office (Bourne End)

// Ethernet Settings - You may need to change the first two
byte mac[] = { 0xDE, 0xAD, 0xBE, 0xEF, 0xFE, 0xED }; 
byte ip[] = { 192, 168, 1, 170 };
Server server(80);
#define BUFSIZ 100

// UDP (which is also part of the Ethernet stuff)
unsigned int localPort = 8888; // We are listening for UDP traffic on Port 8888
byte remoteIP[4];              // When we receive UDP data, this will hold the IP address that sent it
unsigned int remotePort;       // The remote port to send the acknowledgement to
char packetBuffer[24];         // The UDP Packet can be 24 bytes (8 of which are the header). We only need 2 bytes normally and 7 for Time Setting

// Real-Time Clock bits
int rtc[7];                    // 0=Sec, 1=Min, 2=Hour, 3=DOW, 4=Day, 5=Month, 6=Year
  
// SD Card Stuff
Sd2Card card;
SdVolume volume;
SdFile root;
SdFile file;

// We're using a 74HC595 Shift-Register to control the LEDs
#define clockPin 3             // Pin 11 (SH_CP) on the 595
#define latchPin 5             // Pin 12 (ST_CP) on the 595
#define dataPin 6              // Pin 14 (DS)    on the 595

#define switchPin 2            // In Day Mode, pressing this switch will open door

// These modes are stored in a tagMode array and determine type of access or role of a presented RFID Tag
#define failMode 0             // Fairly obvious
#define singleMode 1           // RFID Tag must be presented each time to gain access
#define buttonMode 2           // Used by the Log Routine
#define remoteMode 3           // Remote instruction via the network
#define eraseMode 4            // Erase any tags stored in EEPROM
#define LEDTestMode 5          // LED Test is via the RemoteOpen program
#define dayMode 7              // IT Team Members have Day Mode
#define masterMode 9           // Allow programming of new RFID Tag

#define tagDelay 3000          // On valid RFID Tag, hold door open for 3 seconds
#define bootSpeed 500          // Delay between LED illumination during setup
#define errorSpeed 100         // How fast does the Knight Rider sweep go 
#define flashSpeed 400         // How fast does the flash LED routine go

#define amberLED B00010000     // RFID Tag Successfully Read
#define greenLED B00001000     // RFID Tag Recognised
#define redLED   B00000100     // RFID Tag Not Recognised
#define blueLED  B00000010     // RFID TAG is a Master Tag (for programming other tags)
#define entryLED B00100000     // Entry Authorised
#define openDoor B01000000     // Open the Door so they don't have to press the Button

char tagString[13];            // When a RFID Tag is read, this is where it gets stored
byte tagID = 0;                // The TagID number (0 - n) which we use to look in the allowedTags and tagName arrays
byte tagPresented = 0;         // was an RFID tag just presented?
unsigned long tagPresentedTime = 0;
unsigned long remoteOpenTime = 0;
byte dayModeActive = 0;        // If an IT Team Member opens the door during working hours then engage day mode which will allow the door to be opened by pressing the switch
byte remoteOpen = 0;           // Someone issued a remote (via LAN) request to Open

#define firstDynamicSlot 5     // Where to start storing dynamic tags in allowedTags array
#define dynamicTagSlots 5      // How many new tags can be added 

// If you add any new hard-coded tags, then don't forget to update firstDynamicSlot
char allowedTags[][13] = {
  "XXXXXXXXXXXX",   // FAIL - Should never get this
  "30008BF41659",   // Master Card
  "30008BD91C7E",   // Erase Card
  "4400B091284D",   // Anthony
  "4400B091294C",   // Lynne
  "------------",               // First Dynamic Slot - Will be programmed via the Master Card
  "------------",   // Dynamic - Will be programmed via the Master Card
  "------------",   // Dynamic - Will be programmed via the Master Card
  "------------",   // Dynamic - Will be programmed via the Master Card
  "------------"    // Dynamic - Will be programmed via the Master Card
};

// Only need entries here for the hard-coded tags. The number of entries here should be the same as firstDynamicSlot
char* tagName[] = {
  "!",        // Should never get this
  "Master",
  "Erase",
  "Anthony",
  "Lynne"
};

// There MUST be the same number of entries here as the allowedTags array
byte tagMode[] = {
  failMode,      // Fail
  masterMode,    // Master Card to program new RFID Tags
  eraseMode,     // Erase Card - erases the EEPROM
  dayMode,       // Anthony - IT Team Member
  dayMode,       // Lynne - IT Team Member
  failMode,      // Dynamic Slot 1
  failMode,      // Dynamic Slot 2
  failMode,      // Dynamic Slot 3
  failMode,      // Dyanmic Slot 4
  failMode       // Dyanmic Slot 5
};

// The findTag() function needs to know how many there are
byte numberOfTags = sizeof(allowedTags) / sizeof(allowedTags[0]);

// Here we go
void setup () {
  char logFileName[12];    // This gets modified by the setLogFileName() function 

  // Set up the 74HC595
  pinMode(clockPin, OUTPUT);
  pinMode(latchPin, OUTPUT);
  pinMode(dataPin, OUTPUT);
  
// In Day Mode, this pin provides button access. When the button is pressed, the pin goes LOWA (hence we use the Pull-Up which makes the wiring simpler)
  pinMode(switchPin, INPUT);
  digitalWrite(switchPin, HIGH);   // Activate the Pull-Up Resistor

// Flash the Amber LED three times - lets us know the setup function has begun
  flashLED(amberLED, 3);
  
// If there are any tags stored in EEPROM then load them into the allowedTags array
  loadStoredTags();
  
  setLED(amberLED);                // Illuminate just the Amber LED on (just to show progress)
  delay(bootSpeed);                // Small delay or the setup sequence is too fast
  
  Serial.begin(9600);              // Initialise the Serial
  PgmPrint("Free ");               // Show Free Memory
  Serial.println(FreeRam());       // Well, lets see how little is left!

  RTC.get(rtc,true);               // Get the time from the DS1307 RTC 
  setLogFileName(logFileName);     // Now that we know the date, fix the name[] string
  
  setLED(amberLED | greenLED);     // Illuminate just the Amber & Green LEDs
  delay(bootSpeed); 

  pinMode(10, OUTPUT);             // Whilst we initialise the microSD card
  digitalWrite(10, HIGH);          // we need to turn off the Ethernet chip
  
  card.init(SPI_HALF_SPEED, 4);    // Initalise the microSD card (via Pin 4)
  volume.init(&card);              // Find out what type of File System is on the card
  root.openRoot(&volume);          // Open the card so we can access files

  setLED(amberLED | greenLED | redLED);
  delay(bootSpeed);

  file.writeError = false;         // Clear any write error
  file.open(&root, logFileName, O_CREAT | O_APPEND | O_WRITE);  // Open the file (eg. Feb2011.txt) - create if necessary else append to existing. Allow writing to the file

  file.print("Init at ");          // Put an entry in the Log File
  log_time();                      // Date and Time
  file.println();                  // New Line
  file.close();                    // Close the file - we've finished for the moment

  setLED(amberLED | greenLED | redLED | blueLED);
  delay(bootSpeed);  

  Ethernet.begin(mac, ip);         // Initialise the Ethernet Card
  server.begin();                  // Get ready to run as a Web Server
  Udp.begin(localPort);

  setLED(0x00);                    // Turn off all the LEDs
  delay(bootSpeed * 2);            // Slightly longer pause
  flashLED(greenLED, 2);           // Flash Green LED twice - the setup is done
}

void loop() {
  accessLogServer();               // Is anyone connected to the Web Server?
  remoteOpenRequest();             // Check for any remote requests (via UDP)

  if (dayModeActive == 1 && tagPresented == 0 && remoteOpen == 0) { 
    RTC.get(rtc,true);             // Get the date and time from the DS1307
    if (rtc[2] >= 18) {            // Is it after 6:00pm?
      dayModeActive = 0;           // Turn off Day Mode
      setLED(0x00);                // Turn off all the LEDs
    }
  }

// If they've pressed the button and Day Mode is active then open the door
  if (digitalRead(switchPin) == 0 && dayModeActive == 1) {
    setLED(entryLED | openDoor);              // Not really a LED, but this line going high will activate the Relay and open the door.
    delay(tagDelay);               // Give them a few seconds to get through the door
    setLED(0x00 | (dayModeActive * entryLED));  // If Day Mode is active then 1 x entryLED = entryLED (else 0 x entryLED = 0)!
    delay(500);                    // Short pause
    logAccess(buttonMode);         // Add entry to the Log File
    return;                        // Nothing else to do, so go round the loop() again
  }
  
  if (remoteOpen > 0 && tagPresented == 0) {
    unsigned long remoteWait = remoteOpen;           // remoteWait needs to be same data type as millis()
    remoteWait = remoteWait * 60 * 1000;             // Didn't seem to work as a single sum
    if ((millis() - remoteOpenTime) > remoteWait) {  // This could be up to 4 hours (240 minutes)
      remoteOpen = 0;
      remoteOpenTime = 0;
      dayModeActive = 0;
      setLED(0x00);
    } else {
      dayModeActive = 1;
      setLED(0x00 | entryLED);
    }
  }
  
  if (tagPresented == 1) {         // A tag was recently presented. We pause here even for unauthorised tags (so they can see the Red LED)
    if ((millis() - tagPresentedTime) > tagDelay) {    // Allow a few seconds to get through the door
      tagPresented = 0;            // They've had long enough
      tagPresentedTime = 0;
      setLED(0x00 | (dayModeActive * entryLED));
      return;
    } else {
      Serial.flush();              // Don't accept any other cards for the moment
      return;
    }
  }

  if (Serial.available()) {           // Looks like someone has waved an RFID tag in front of our sensor
    byte RFID_Status = get_RFID();    // 0 means got a RFID Tag, anything else is an error
    tagPresented = 0;                 // Make sure this is cleared

    if (RFID_Status == 0) {
        processTag();                 // Got an RFID Tag - Let's decide what to do
        tagPresented = 1;             // Set this so that the delay happens 
        tagPresentedTime = millis();  // The clock starts now 
        return;                       // Back round the loop()
    }
    errorLED(RFID_Status);            // Didn't get an RFID tag. Probably aliens
  }
}

void setLogFileName(char logFileName[12]) {  // Initially, the logFileName[] string is defined as XXX9999.txt but this function will change it to something like Feb2011.txt
  char shortmonth[12][4] = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
  char yyyy[5];

  for (byte i = 0; i < 3; i++) {        // Change the first 3 characters of name[]
    logFileName[i] = shortmonth[rtc[5]-1][i];// Copy the characters from the Month
  }
  itoa(rtc[6],yyyy,10);               // Convert the year (which is a number) to a 4 character string (which we'll store in yyyy)
  for (byte i = 0; i < 4; i++) {       // Copy the four characters of the year
    logFileName[i+3] = yyyy[i];              // in to positions 4 to 7 of the name[]
  }
  logFileName[7]  = '.';
  logFileName[8]  = 't';
  logFileName[9]  = 'x';
  logFileName[10] = 't';
  logFileName[11] = '\0';
}

void processTag() {
  if (tagID == 0) {                   // Don't recognise the tag 
    setLED(amberLED | redLED);        // Amber means we got a tag, but Red means it's NOT authorised
    logAccess(tagMode[tagID]);        // Log the event
    return;                           // Nothing else to do.
  }
  
  if (tagMode[tagID] == failMode) {   // Bit of a bobo if we get here. Check the tagMode[] array
    errorLED(1);                      // Error 1: Tag is recognised but tagMode array doesn't have correct access mode
    setLED(amberLED);                 // Just the Amber LED (RFID Tag read)
    logAccess(tagMode[tagID]);        // Log entry
    return;
  }
  
  if (tagMode[tagID] == eraseMode) {  // Erase Card presented
    clearTagEEPROM();                 // Clear ALL the dynmaic tags
    logAccess(tagMode[tagID]);        // Log entry
    setLED(0x00);                     // Turn off all the LEDs
    return;
  }
  
  Serial.println(tagID);

  if (tagMode[tagID] == masterMode) { // Master Card present - we don't take Visa
    setLED(amberLED | blueLED);       // Indicate accordingly
    logAccess(tagMode[tagID]);        // Log the Master Card
    Serial.flush();                   // Clear the Serial buffer. Sometimes, pulling the Master Card away actually sends the data again
    delay(1500);                      // Allow 1.5 seconds for Master Card to be removed
    if (Serial.available()) {         // If there's anything in the Serial Buffer, keep clearing it till it's empty
      Serial.flush();                 // Empty the Serial buffer
    }
// OK. We're now ready to look for the next presented RFID Tag. If nothing arrives for 10 seconds then drop out.
    unsigned long programStartTime = millis();      // Make a note of the time
    while ((millis() - programStartTime) < 10000) { // You've got 10 seconds
      if (Serial.available()) break ; // Anything present to the RFID sensor yet?
    }
    if (Serial.available() == 0) {    // Nothing presented - nothing to do
      setLED(0x00);                   // Turn off the LEDs 
      return;
    }
    byte newTag = get_RFID();         // A new tag is available, lets get it
    if (newTag != 0) {                // Something went wrong - whatever data we got wasn't a valid RFID Tag
      setLED(0x00);                   // Not much we can do. Turn off the LEDs
      errorLED(2);                    // Error 2: Duff RFID tag data
      setLED(0x00);                   // Turn everything off
      return;
    }
    
    if (tagID != 0) {                 // Already got this RFID in our lookup table - don't want a duplicate
      errorLED(3);                    // Error 3: Trying to program an already know RFID
      setLED(0x00);                   // Turn everything off
      return;
    }

// We've got this far and everything looks good. Let's save the new Tag in one of our dynamic slots
    byte eSlot = storeTagEEPROM(tagString);
    if (eSlot == 99) return;          // Failed - probably no free slots
    setLED(greenLED);                 // Success. Green LED to show it
    delay(1000);                      // Wait for a second
    flashLED(amberLED | greenLED | redLED | blueLED, eSlot + 1);   // The first slot is zero, but it's difficult to flash zero
    delay(250);                       // Brief pause
    setLED(0x00);                     // Turn it all off
    return;
  }
  
// Open the Door. If we get this far, then the tag presented is authorised to access. As well as turning the LEDs on, we also open the door. 
// Have a look in the setLED function to see how.
  setLED(amberLED | greenLED | entryLED | openDoor);

  if (tagMode[tagID] == dayMode) {    // If it's a DayMode tag, then toggle the DayMode
// Should be a check here to see what time of day it is
    if (dayModeActive)                // Is Day Mode active at the moment?
      dayModeActive = 0;              // Turn it off
    else
      dayModeActive = 1;              // Turn on Day Mode
  }

  logAccess(tagMode[tagID]);          // Make a note in the Log File
  
  delay(250);                         // Wait here for 1/4 second 
}

byte get_RFID() {                     // Read the RFID data
  byte val = 0;
  byte byte_count = 0;
  tagID = 0;
    
  if (Serial.available() == 0) {      // No Serial data available - shouldn't ever get here!
    return(5);                        // Error 5: Thought I saw an RFID card, but it's not there any more
  }
  
// If the first byte we get isn't a 0x02 then something has gone wrong. Best thing to do is flush the serial buffer and let them try again.
  if (Serial.read() != 0x02) {
    Serial.flush();                   // Clear the serial buffer - it's just full of rubbish
    return(6);                        // Error 6: Bad data format
  }
    
// Make a note of the time - don't want to get stuck in here waiting for data that's never going to arrive
  unsigned long RFID_StartTime = millis();
  
  while (byte_count < 12) {           // The actual RFID Tag ID is a 12 byte sequence
    if (Serial.available() == 0) {    // If there's nothing in the serial buffer
      if ((millis() - RFID_StartTime) > 500) {   // Allow 0.5 seconds to read the RFID
        Serial.flush();               // Clear any data
        return(7);                    // Error 7: Partial data
      }
      continue;
    }
      
    val = Serial.read();              // Byte in the Buffer, Moo, Moo, Moo
    tagString[byte_count] = val;      // Save it
    byte_count++;                     // Keep track of how many arrived
  }
  tagString[12] = '\0';               // Terminate the RFID Tag string

  setLED(amberLED);                   // We've successfully read the RFID Tag
    
  tagID = findTag(tagString);         // Let's see if it's one we recognise
  
  Serial.flush();                     // Clear any remaining bits in the buffer
  
  return(0);                          // 0 means its OK. The global variable tagID will tell calling function which RFID Tag was presented
}

int findTag(char tagValue[12]) {      // See if the Tag is one we recognise
// The first entry in allowedTags is FAIL, so we can ignore it (hence the loops starts at 1). If we return 0, then we know it's a fail  
  for (byte thisCard = 1; thisCard < numberOfTags; thisCard++) {
    if (strcmp(tagValue, allowedTags[thisCard]) == 0) {
      return(thisCard);               // Return index to allowedTags[] array
    }
  }
  return(0);                          // Didn't find it - hence 0
}

// The setLED function is actually sending data to the 74HC595 Shift Register
// Most of the outputs are indeed connected to LEDs, but one is actually
// driving the transistor that turns the Relay on. At the start of the program
// you'll see I define the various LEDs (eg. amberLED) as a byte with a single
// bit set. This bit corresponds with a output from the 595. By using the 
// binary OR operator ( | ) you can turn on combinations of LEDs
void setLED(byte ledStatus) {
  digitalWrite(latchPin, LOW);        // Set Latch LOW - we're about to shift some data in
  shiftOut(dataPin, clockPin, MSBFIRST, ledStatus);
  digitalWrite(latchPin, HIGH);       // Set Latch HIGH - the output are now active
}

void errorLED(byte errMSG) { 
  for (byte i = 0; i < 2; i++) {       // Going to do a Knight Ride sweep of the LEDs
    setLED(amberLED);
    delay(errorSpeed);
    setLED(greenLED);
    delay(errorSpeed);
    setLED(redLED);
    delay(errorSpeed);
    setLED(blueLED);
    delay(errorSpeed);
    setLED(redLED);
    delay(errorSpeed);
    setLED(greenLED);
    delay(errorSpeed);
  }
  setLED(0x00);                      // Turn all the LEDs off
  if (errMSG == 0) return;           // No error message
  delay(500);                        // Brief pause - get ready to count the Red Flashes
  flashLED(redLED, errMSG);          // Flash Red LED to indicate error number
  setLED(0x00);                      // Turn everything off
}

void flashLED(byte whichLED, byte flashCount) {
  for (byte flashLoop = 0; flashLoop < flashCount; flashLoop++) {
    setLED(whichLED);                // Turn the LED on
    delay(flashSpeed);               // Wait a bit
    setLED(0x00);                    // Turn the LED off
    delay(flashSpeed);               // Wait a big
  }
}

// Some of the RFID Tags are hard coded into the source, but others are programmed after the unit has been installed. If the power is removed, we
// don't want to lose any of the dynamic tags, we store them in the 512 bytes of EEPROM that the Arduino has. Each slot is 12 bytes and there's no
// terminator (so slot 2 starts at byte 13). A 0x00 in the first byte of a slot indicates that the slot is empty (hopefully, RFID ID tag numbers won't 
// begin with a zero).
void loadStoredTags() {
  for (byte tagSlot = 0; tagSlot < dynamicTagSlots; tagSlot++) {
    if (EEPROM.read((tagSlot * 12)) == 0) {   // If the first byte is zero, the slot is empty
      continue;
    }
// Copy the twelve bytes to the allowedTags array.
    for (byte tagByte = 0; tagByte < 12; tagByte++) {
      allowedTags[tagSlot + firstDynamicSlot][tagByte] = EEPROM.read((tagSlot * 12) + tagByte);
// All dynamic rfid tags are singleMode 
      tagMode[tagSlot + firstDynamicSlot] = singleMode;
    }
  }
}

// Save a tag. This is called by the Master Card routine
byte storeTagEEPROM(char tagValue[12]) {
  int addr = 0;
  byte tagSlot = 0;
  byte tagByte = 0;

// Find a Spare Slot in EEPROM
  for (tagSlot = 0; tagSlot < dynamicTagSlots; tagSlot++) {
    addr = tagSlot * 12;              // Each slot is 12 bytes
    if (EEPROM.read(addr) == 0x00) {  // Is the slot empty?
      break;                          // Yep 
    }
  }
  if (tagSlot == dynamicTagSlots) {   // No free slots
    errorLED(4);                      // Error 4: No Free EEPROM slots
    return(99);                       // Let the calling routine know
  }
        
// Store the new RFID Tag in EEPROM
  for (tagByte = 0; tagByte < 12; tagByte++) {
    addr = (tagSlot * 12) + tagByte;
    EEPROM.write(addr, tagValue[tagByte]);
  }
  
// Store the new RFID Tag in the lookup table so that'll it work straight away
  for (tagByte = 0; tagByte < 12; tagByte++) {
    allowedTags[tagSlot + firstDynamicSlot][tagByte] = tagValue[tagByte];
    tagMode[tagSlot + firstDynamicSlot] = singleMode;
  }
  
  return(tagSlot);                    // Let the calling function know which slot
}

void clearTagEEPROM() {               // Called when the Erase Card is presented
  int addr = 0;
  byte tagSlot = 0;
  byte tagByte = 0;
  
// First we erase the EEPROM slots
  for (tagSlot = 0; tagSlot < dynamicTagSlots; tagSlot++) {
    flashLED(amberLED | blueLED, 1);  // Flash some LEDs whilst erasing
    for (tagByte = 0; tagByte < 12; tagByte++) {
      addr = (tagSlot * 12) + tagByte;
      EEPROM.write(addr, 0);
    }
  }

// Then erase the dynamic slots in the allowedTags[] array
  for (tagSlot = 0; tagSlot < dynamicTagSlots; tagSlot++) {
    flashLED(greenLED | redLED, 1);  // Flash some LEDs whilst erasing
    for (tagByte = 0; tagByte < 12; tagByte++) {
      allowedTags[tagSlot + firstDynamicSlot][tagByte] = '-';
      tagMode[tagSlot + firstDynamicSlot] = failMode;
    }
  }   
}

// This function adds an entry to the Log File whenever an RFID Tag is presented
void logAccess(byte aMode) {
  char logFileName[12];               // This gets modified by the setLogFileName() function 

  setLogFileName(logFileName);                         // It could have been weeks since anyone accessed, so the month (or year) may have changed since the setup() was called.
// Open the Log File (or create if it doesn't exist) and allow appending
  file.open(&root, logFileName, O_CREAT | O_APPEND | O_WRITE);

  switch (aMode) {                   // Check the access mode
    case (failMode): {               // Fail / Denied
      file.print("Denied: ");
      log_time();
      file.print(" to ");
      file.println(tagString);
      file.close();
      break;
    }
    case (buttonMode): {            // Button pressed (in day mode) so we won't have an RFID Tag
      file.print("Button: ");
      log_time();
      file.println();
      file.close();
      break;
    }
    case (LEDTestMode): {           // LED Test so we won't have an RFID Tag
      file.print("LED Test: ");
      log_time();
      file.println();
      file.close();
      break;
    }
    case (remoteMode): {            // Network Open so we won't have an RFID Tag
      file.print("Remote: ");
      log_time();
      file.println();
      file.close();
      break;
    }
    case (dayMode):                 // Access Authorised
    case (singleMode): {
      file.print("Access: ");
      break;
    }
    case (eraseMode): {             // Erase Card Presented
      file.print("Erase:  ");
      break;
    }
    case (masterMode): {            // Master Card - That'll Do Nicely!
      file.print("Master: ");
      break;
    }
  }

// Just return if we don't have an RFID Tag to add to the log entry
  if (aMode == failMode || aMode == buttonMode) return;
  
  log_time();                       // Record the Date and Time
  file.print(" by ");
  file.print(tagString);
  file.print(" (");
  if (tagID < firstDynamicSlot) {   // It's a static Tag so we have a name
    file.print(tagName[tagID]);
  } else {
    file.print("Dynamic ");         // Just print Dynamic and the slot number
    file.print(tagID - firstDynamicSlot + 1);
  }  
  file.print(")");
  file.println();
  file.close();
}

void log_time() {
  char daynames[7][4] = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
  char shortmonth[12][4] = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

  RTC.get(rtc,true);                      // Get the date and time from the DS1307
  file.print(&daynames[rtc[3]-1][0]);     // Day of the Week (Mon, Tue etc)
  file.print(' ');
  file.print(rtc[4]);                     // Date of the Month (eg. 26)
  file.print(' ');
  file.print(&shortmonth[rtc[5]-1][0]);   // Month (Oct, Nov etc)
  file.print(' ');
  file.print(rtc[6]);                     // Year (eg. 2011)

  file.print(" at ");  
  NumberPrint(rtc[2]);                    // Hours (with 0 prefix if 9 or less)
  file.print(':');
  NumberPrint(rtc[1]);                    // Minutes
  file.print(':');
  NumberPrint(rtc[0]);                    // Seconds
}

// We want the time to appear nice - ie. 09:04:37 not 9:4:37
void NumberPrint(int whatNumber) {
  if (whatNumber <= 9) file.print('0');
  file.print(whatNumber);
}


void remoteOpenRequest() {            // Check if a Remote (across the LAN) request has been made 
  int packetSize = Udp.available();   // This includes the UDP header
  if(packetSize) {
    packetSize = packetSize - 8;      // subtract the 8 byte header
    Udp.readPacket(packetBuffer,24, remoteIP, remotePort);   // Read into packetBufffer and get senders IP addr and port
    
    unsigned long remoteWait = remoteOpen;
    remoteWait = remoteWait * 60 * 1000;

    switch (packetBuffer[0]) {
      case 'L':                       // Lights Test (Confidence Test)
        errorLED(0);
        setLED(0x00 | (dayModeActive * entryLED));
        logAccess(LEDTestMode);
        break;
        
      case 'O':                       // Open
        remoteOpenTime = millis();
        setLED(entryLED | openDoor);
        remoteOpen = packetBuffer[1];
        if (remoteOpen == 0) remoteOpen = 1;
        dayModeActive = 1;
        setLED(entryLED | openDoor);
        delay(10000);
        setLED(0x00 | (dayModeActive * entryLED));
        logAccess(remoteMode);
        break;
    
      case 'S':                       // Secure - Turn off Day Mode and remoteOpen
        setLED(0x00);
        dayModeActive = 0;
        remoteOpen = 0;
        tagPresented = 0 ;
        break;

      case 'I':                       // Secure - Turn off Day Mode and remoteOpen
        Serial.println();
        Serial.println(int(dayModeActive));
        Serial.println(int(remoteOpen));
        Serial.println(remoteOpenTime);
        Serial.println(int(tagPresented));
        Serial.println(tagPresentedTime);
        Serial.println(millis());
        Serial.println(remoteWait);
        break;

      case 'T':                        // Set the Date and Time
        RTC.stop();                    // Stop the clock whilst we set it
        RTC.set(DS1307_SEC, 0);        // Seconds
        RTC.set(DS1307_HR, packetBuffer[1]);
        RTC.set(DS1307_MIN, packetBuffer[2]);
        RTC.set(DS1307_DOW, packetBuffer[3]);  // 1=Monday, 2=Tuesday 7=Sunday etc.
        RTC.set(DS1307_DATE, packetBuffer[4]);
        RTC.set(DS1307_MTH, packetBuffer[5]);
        RTC.set(DS1307_YR, packetBuffer[6]);   // Pass 11 for 2011
        RTC.start();                   // Start the Clock
        logAccess(remoteMode);
    }
    Udp.sendPacket("OK", remoteIP, remotePort);
    delay(10);
  }
}


// This Web Server code has been shameless lifted from AdaFruit's demo

// Web Server
void ListFiles(Client client, uint8_t flags) {
  // This code is just copied from SdFile.cpp in the SDFat library
  // and tweaked to print to the client output in html!
  dir_t p;
  
  root.rewind();
  client.println("<ul>");
  while (root.readDir(p) > 0) {
    // done if past last used entry
    if (p.name[0] == DIR_NAME_FREE) break;

    // skip deleted entry and entries for . and  ..
    if (p.name[0] == DIR_NAME_DELETED || p.name[0] == '.') continue;

    // only list subdirectories and files
    if (!DIR_IS_FILE_OR_SUBDIR(&p)) continue;

    // print any indent spaces
    client.print("<li><a href=\"");
    for (uint8_t i = 0; i < 11; i++) {
      if (p.name[i] == ' ') continue;
      if (i == 8) {
        client.print('.');
      }
      client.print(p.name[i]);
    }
    client.print("\">");
    
    // print file name with possible blank fill
    for (uint8_t i = 0; i < 11; i++) {
      if (p.name[i] == ' ') continue;
      if (i == 8) {
        client.print('.');
      }
      client.print(p.name[i]);
    }
    
    client.print("</a>");
    
    if (DIR_IS_SUBDIR(&p)) {
      client.print('/');
    }

    // print modify date/time if requested
    if (flags & LS_DATE) {
       root.printFatDate(p.lastWriteDate);
       client.print(' ');
       root.printFatTime(p.lastWriteTime);
    }
    // print size if requested
    if (!DIR_IS_SUBDIR(&p) && (flags & LS_SIZE)) {
      client.print(' ');
      client.print(p.fileSize);
    }
    client.println("</li>");
  }
  client.println("</ul>");
}

void accessLogServer()
{
  char* http200[] = {
  "HTTP/1.1 200 OK",
  "Content-Type: text/",
  "html",
  "plain"
  };

  char clientline[BUFSIZ];
  int index = 0;
  
  Client client = server.available();
  if (client) {
    // an http request ends with a blank line
    boolean current_line_is_blank = true;
    
    // reset the input buffer
    index = 0;
    PgmPrint("Free ");          // Show Free Memory
    Serial.println(FreeRam());       // Well, lets see how little is left!

    while (client.connected()) {
      if (client.available()) {
        char c = client.read();
        
        // If it isn't a new line, add the character to the buffer
        if (c != '\n' && c != '\r') {
          clientline[index] = c;
          index++;
          // are we too big for the buffer? start tossing out data
          if (index >= BUFSIZ) 
            index = BUFSIZ -1;
          
          // continue to read more data!
          continue;
        }
        
        // got a \n or \r new line, which means the string is done
        clientline[index] = 0;
        
        // Print it out for debugging
        Serial.println(clientline);
        
        // Look for substring such as a request to get the root file
        if (strstr(clientline, "GET / ") != 0) {
          // send a standard http response header
          client.println(http200[0]);
          client.print(http200[1]);
          client.println(http200[2]);
          client.println();
          
          // print all the files, use a helper to keep it clean
          client.println("<h2>Access Log for LS</h2>");
          ListFiles(client, LS_SIZE);
        } else if (strstr(clientline, "GET /") != 0) {
          // this time no space after the /, so a sub-file!
          char *filename;
          
          filename = clientline + 5; // look after the "GET /" (5 chars)
          // a little trick, look for the " HTTP/1.1" string and 
          // turn the first character of the substring into a 0 to clear it out.
          (strstr(clientline, " HTTP"))[0] = 0;
          
          // print the file we want
          Serial.println(filename);
          
// Remove the file they clicked on          
//          file.open(&root, filename, O_WRITE);
//          file.remove();
//          break;
          

          if (! file.open(&root, filename, O_READ)) {
//            client.println("HTTP/1.1 404 Not Found");
//            client.println("Content-Type: text/html");
//            client.println();
//            client.println("<h2>File Not Found!</h2>");
            break;
          }


//          Serial.println("Opened!");
                    
          client.println(http200[0]);
          client.print(http200[1]);
          client.println(http200[3]);
          client.println();
          
          int16_t c;
          while ((c = file.read()) > 0) {
              // uncomment the serial to debug (slow!)
              //Serial.print((char)c);
              client.print((char)c);
          }
          file.close();
        } else {
          // everything else is a 404
//          client.println("HTTP/1.1 404 Not Found");
//         client.println("Content-Type: text/html");
//          client.println();
//          client.println("<h2>File Not Found!</h2>");
        }
        break;
      }
    }
    // give the web browser time to receive the data
    delay(1);
    client.stop();
  }
}


