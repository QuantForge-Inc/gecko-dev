/* -*- Mode: C++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1/GPL 2.0/LGPL 2.1
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is mozilla.org code.
 *
 * The Initial Developer of the Original Code is
 * Netscape Communications Corporation.
 * Portions created by the Initial Developer are Copyright (C) 1998
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *   Josh Aas <josh@mozilla.com>
 *
 * Alternatively, the contents of this file may be used under the terms of
 * either the GNU General Public License Version 2 or later (the "GPL"), or
 * the GNU Lesser General Public License Version 2.1 or later (the "LGPL"),
 * in which case the provisions of the GPL or the LGPL are applicable instead
 * of those above. If you wish to allow use of your version of this file only
 * under the terms of either the GPL or the LGPL, and not to allow others to
 * use your version of this file under the terms of the MPL, indicate your
 * decision by deleting the provisions above and replace them with the notice
 * and other provisions required by the GPL or the LGPL. If you do not delete
 * the provisions above, a recipient may use your version of this file under
 * the terms of any one of the MPL, the GPL or the LGPL.
 *
 * ***** END LICENSE BLOCK ***** */

#include "nsCOMPtr.h"
#include "nsIDocument.h"
#include "nsIContent.h"
#include "nsIDOMDocument.h"
#include "nsIDocumentViewer.h"
#include "nsIDocumentObserver.h"
#include "nsIComponentManager.h"
#include "nsIDocShell.h"
#include "prinrval.h"

#include "nsMenuX.h"
#include "nsMenuBarX.h"
#include "nsIMenu.h"
#include "nsIMenuBar.h"
#include "nsIMenuItem.h"
#include "nsIMenuListener.h"
#include "nsPresContext.h"
#include "nsIMenuCommandDispatcher.h"

#include "nsString.h"
#include "nsReadableUtils.h"
#include "nsUnicharUtils.h"
#include "plstr.h"

#include "nsINameSpaceManager.h"
#include "nsWidgetAtoms.h"
#include "nsIXBLService.h"
#include "nsIServiceManager.h"

#include "nsGUIEvent.h"

#include "nsCRT.h"

static PRBool gConstructingMenu = PR_FALSE;

static MenuRef GetCarbonMenuRef(NSMenu* aMenu);

// CIDs
#include "nsWidgetsCID.h"
static NS_DEFINE_CID(kMenuCID,     NS_MENU_CID);
static NS_DEFINE_CID(kMenuItemCID, NS_MENUITEM_CID);

// Refcounted class for dummy menu items, like separators and help menu items.
class nsDummyMenuItemX : public nsISupports {
public:
    NS_DECL_ISUPPORTS

    nsDummyMenuItemX()
    {
    }
};

NS_IMETHODIMP_(nsrefcnt) nsDummyMenuItemX::AddRef() { return ++mRefCnt; }
NS_IMETHODIMP nsDummyMenuItemX::Release() { return --mRefCnt; }
NS_IMPL_QUERY_INTERFACE0(nsDummyMenuItemX)
static nsDummyMenuItemX gDummyMenuItemX;


NS_IMPL_ISUPPORTS4(nsMenuX, nsIMenu, nsIMenuListener, nsIChangeObserver, nsISupportsWeakReference)


nsMenuX::nsMenuX()
: mNumMenuItems(0), mParent(nsnull), mManager(nsnull),
  mMacMenuID(0), mMacMenu(NULL), mHelpMenuOSItemsCount(0),
  mIsHelpMenu(PR_FALSE), mIsEnabled(PR_TRUE), mDestroyHandlerCalled(PR_FALSE),
  mNeedsRebuild(PR_TRUE), mConstructed(PR_FALSE), mVisible(PR_TRUE), mHandler(nsnull)
{
    mMenuDelegate = [[MenuDelegate alloc] initWithGeckoMenu:this];
}


nsMenuX::~nsMenuX()
{
  RemoveAll();

  if (mMacMenu) {
    if (mHandler)
      ::RemoveEventHandler(mHandler);
    [mMacMenu release];
  }
  
  [mMenuDelegate release];
  
  // alert the change notifier we don't care no more
  mManager->Unregister(mMenuContent);
}


NS_IMETHODIMP 
nsMenuX::Create(nsISupports * aParent, const nsAString &aLabel, const nsAString &aAccessKey, 
                nsIChangeManager* aManager, nsIDocShell* aShell, nsIContent* aNode )
{
  mDocShellWeakRef = do_GetWeakReference(aShell);
  mMenuContent = aNode;

  // register this menu to be notified when changes are made to our content object
  mManager = aManager; // weak ref
  nsCOMPtr<nsIChangeObserver> changeObs(do_QueryInterface(NS_STATIC_CAST(nsIChangeObserver*, this)));
  mManager->Register(mMenuContent, changeObs);

  NS_ASSERTION(mMenuContent, "Menu not given a dom node at creation time");
  NS_ASSERTION(mManager, "No change manager given, can't tell content model updates");

  mParent = aParent;
  // our parent could be either a menu bar (if we're toplevel) or a menu (if we're a submenu)
  nsCOMPtr<nsIMenuBar> menubar = do_QueryInterface(aParent);
  nsCOMPtr<nsIMenu> menu = do_QueryInterface(aParent);
  NS_ASSERTION(menubar || menu, "Menu parent not a menu bar or menu!");

  SetLabel(aLabel);
  SetAccessKey(aAccessKey);

  nsAutoString hiddenValue, collapsedValue;
  mMenuContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::hidden, hiddenValue);
  mMenuContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::collapsed, collapsedValue);
  if (hiddenValue.EqualsLiteral("true") || collapsedValue.EqualsLiteral("true"))
    mVisible = PR_FALSE;

  if (menubar && mMenuContent->GetChildCount() == 0)
    mVisible = PR_FALSE;

  return NS_OK;
}


NS_IMETHODIMP nsMenuX::GetParent(nsISupports*& aParent)
{
  aParent = mParent;
  NS_IF_ADDREF(aParent);
  return NS_OK;
}


NS_IMETHODIMP nsMenuX::GetLabel(nsString &aText)
{
  aText = mLabel;
  return NS_OK;
}


NS_IMETHODIMP nsMenuX::SetLabel(const nsAString &aText)
{
  mLabel = aText;
  // create an actual NSMenu if this is the first time
  if (mMacMenu == NULL)
    mMacMenu = CreateMenuWithGeckoString(mLabel);
  return NS_OK;
}


NS_IMETHODIMP nsMenuX::GetAccessKey(nsString &aText)
{
  return NS_OK;
}


NS_IMETHODIMP nsMenuX::SetAccessKey(const nsAString &aText)
{
  return NS_OK;
}


NS_IMETHODIMP nsMenuX::AddItem(nsISupports* aItem)
{
  nsresult rv = NS_ERROR_FAILURE;
  if (aItem) {
    // Figure out what we're adding
    nsCOMPtr<nsIMenuItem> menuItem(do_QueryInterface(aItem));
    if (menuItem) {
      rv = AddMenuItem(menuItem);
    } else {
      nsCOMPtr<nsIMenu> menu(do_QueryInterface(aItem));
      if (menu)
        rv = AddMenu(menu);
    }
  }
  return rv;
}


NS_IMETHODIMP nsMenuX::AddMenuItem(nsIMenuItem * aMenuItem)
{
  if (!aMenuItem)
    return NS_ERROR_NULL_POINTER;

  PRUint32 currItemIndex;
  mMenuItemsArray.Count(&currItemIndex);
  mMenuItemsArray.AppendElement(aMenuItem); // owning ref

  mNumMenuItems++;

  nsAutoString label;
  aMenuItem->GetLabel(label);
  InsertMenuItemWithTruncation(label, currItemIndex);
  
  NSMenuItem *newNativeMenuItem = [mMacMenu itemAtIndex:currItemIndex];
  
  // set up shortcut keys
  nsAutoString geckoKeyEquivalent(NS_LITERAL_STRING(" "));
  aMenuItem->GetShortcutChar(geckoKeyEquivalent);
  NSString *keyEquivalent = [[NSString stringWithCharacters:(unichar*)geckoKeyEquivalent.get()
                                                     length:geckoKeyEquivalent.Length()] lowercaseString];
  if (![keyEquivalent isEqualToString:@" "])
    [newNativeMenuItem setKeyEquivalent:keyEquivalent];
  
  // set up shortcut key modifiers
  PRUint8 modifiers;
  aMenuItem->GetModifiers(&modifiers);
  unsigned int macModifiers = 0;
  if (knsMenuItemShiftModifier & modifiers)
    macModifiers |= NSShiftKeyMask;
  if (knsMenuItemAltModifier & modifiers)
    macModifiers |= NSAlternateKeyMask;
  if (knsMenuItemControlModifier & modifiers)
    macModifiers |= NSControlKeyMask;
  if (knsMenuItemCommandModifier & modifiers)
    macModifiers |= NSCommandKeyMask;
  [newNativeMenuItem setKeyEquivalentModifierMask:macModifiers];

  /*
  // set its command. we get the unique command id from the menubar
  //XXXJOSH we should no longer handle this with carbon events
  nsCOMPtr<nsIMenuCommandDispatcher> dispatcher(do_QueryInterface(mManager));
  if (dispatcher) {
    PRUint32 commandID = 0L;
    dispatcher->Register(aMenuItem, &commandID);
    if (commandID)
      ::SetMenuItemCommandID(mMacMenu, currItemIndex, commandID);
  }
   */
  
  PRBool isEnabled;
  aMenuItem->GetEnabled(&isEnabled);
  if (isEnabled)
    [newNativeMenuItem setEnabled:YES];
  else
    [newNativeMenuItem setEnabled:NO];

  PRBool isChecked;
  aMenuItem->GetChecked(&isChecked);
  if (isChecked)
    [newNativeMenuItem setState:NSOnState];
  else
    [newNativeMenuItem setState:NSOffState];

  return NS_OK;
}


NS_IMETHODIMP nsMenuX::AddMenu(nsIMenu * aMenu)
{
  // Add a submenu
  if (!aMenu)
    return NS_ERROR_NULL_POINTER;

  nsCOMPtr<nsISupports> supports = do_QueryInterface(aMenu);
  if (!supports)
    return NS_ERROR_NO_INTERFACE;

  PRUint32 currItemIndex;
  mMenuItemsArray.Count(&currItemIndex);
  mMenuItemsArray.AppendElement(supports); // owning ref
  mNumMenuItems++;

  // We have to add it as a menu item and then associate it with the item
  nsAutoString label;
  aMenu->GetLabel(label);
  InsertMenuItemWithTruncation(label, currItemIndex);

  PRBool isEnabled;
  aMenu->GetEnabled(&isEnabled);
  if (isEnabled)
    [[mMacMenu itemAtIndex:currItemIndex] setEnabled:YES];
  else
    [[mMacMenu itemAtIndex:currItemIndex] setEnabled:NO];   

  NSMenu* childMenu;
  if (aMenu->GetNativeData((void**)&childMenu) == NS_OK) {
    [[mMacMenu itemAtIndex:currItemIndex] setSubmenu:childMenu];
  }
  return NS_OK;
}


//
// InsertMenuItemWithTruncation
//
// Insert a new item in this menu with index |inItemIndex| with the text |inItemLabel|,
// middle-truncated to a certain pixel width with an elipsis.
//
void
nsMenuX::InsertMenuItemWithTruncation(nsAutoString & inItemLabel, PRUint32 inItemIndex)
{
  // ::TruncateThemeText() doesn't take the number of characters to truncate to, it takes a pixel with
  // to fit the string in. Ugh. I talked it over with sfraser and we couldn't come up with an 
  // easy way to compute what this should be given the system font, etc, so we're just going
  // to hard code it to something reasonable and bigger fonts will just have to deal.
  const short kMaxItemPixelWidth = 300;

  CFMutableStringRef labelRef = ::CFStringCreateMutable(kCFAllocatorDefault, inItemLabel.Length());
  ::CFStringAppendCharacters(labelRef, (UniChar*)inItemLabel.get(), inItemLabel.Length());
  ::TruncateThemeText(labelRef, kThemeMenuItemFont, kThemeStateActive, kMaxItemPixelWidth, truncMiddle, NULL);
  [mMacMenu insertItem:[[[NSMenuItem alloc] initWithTitle:(NSString*)labelRef action:NULL keyEquivalent:@""] autorelease] atIndex:(inItemIndex)];
  ::CFRelease(labelRef);
} // InsertMenuItemWithTruncation


NS_IMETHODIMP nsMenuX::AddSeparator()
{
  // We're not really appending an nsMenuItem but it needs to be here to make
  // sure that event dispatching isn't off by one.
  mMenuItemsArray.AppendElement(&gDummyMenuItemX); // owning ref
  PRUint32  numItems;
  mMenuItemsArray.Count(&numItems);
  [mMacMenu addItem:[NSMenuItem separatorItem]];
  mNumMenuItems++;
  return NS_OK;
}


NS_IMETHODIMP nsMenuX::GetItemCount(PRUint32 &aCount)
{
  return mMenuItemsArray.Count(&aCount);
}


NS_IMETHODIMP nsMenuX::GetItemAt(const PRUint32 aPos, nsISupports *& aMenuItem)
{
  mMenuItemsArray.GetElementAt(aPos, &aMenuItem);
  return NS_OK;
}


NS_IMETHODIMP nsMenuX::InsertItemAt(const PRUint32 aPos, nsISupports * aMenuItem)
{
  NS_ASSERTION(0, "Not implemented");
  return NS_OK;
}


NS_IMETHODIMP nsMenuX::RemoveItem(const PRUint32 aPos)
{
  //XXXJOSH Implement this
  NS_WARNING("Not implemented");
  return NS_OK;
}


NS_IMETHODIMP nsMenuX::RemoveAll()
{
  //XXXJOSH why don't we set |mNumMenuItems| to 0 after removing all menu items?
  if (mMacMenu != NULL) {
    /*
    // clear command id's
    nsCOMPtr<nsIMenuCommandDispatcher> dispatcher(do_QueryInterface(mManager));
    if (dispatcher) {
      for (unsigned int i = 1; i <= mNumMenuItems; ++i) {
        PRUint32 commandID = 0L;
        OSErr err = ::GetMenuItemCommandID(mMacMenu, i, (unsigned long*)&commandID);
        if (!err)
          dispatcher->Unregister(commandID);
      }
    }
     */
    for (int i = [mMacMenu numberOfItems] - 1; i >= 0; i--) {
      [mMacMenu removeItemAtIndex:i];
    }
  }
  
  mMenuItemsArray.Clear(); // remove all items
  return NS_OK;
}


NS_IMETHODIMP nsMenuX::GetNativeData(void ** aData)
{
  *aData = mMacMenu;
  return NS_OK;
}


NS_IMETHODIMP nsMenuX::SetNativeData(void * aData)
{
  [mMacMenu release];
  mMacMenu = [(NSMenu*)aData retain];
  return NS_OK;
}


NS_IMETHODIMP nsMenuX::AddMenuListener(nsIMenuListener * aMenuListener)
{
  mListener = aMenuListener; // strong ref
  return NS_OK;
}


NS_IMETHODIMP nsMenuX::RemoveMenuListener(nsIMenuListener * aMenuListener)
{
  if (aMenuListener == mListener)
    mListener = nsnull;
  return NS_OK;
}


//
// nsIMenuListener interface
//


nsEventStatus nsMenuX::MenuItemSelected(const nsMenuEvent & aMenuEvent)
{
  // all this is now handled by Carbon Events.
  return nsEventStatus_eConsumeNoDefault;
}


nsEventStatus nsMenuX::MenuSelected(const nsMenuEvent & aMenuEvent)
{
  // printf("JOSH: MenuSelected called for %s \n", NS_LossyConvertUCS2toASCII(mLabel).get());
  nsEventStatus eventStatus = nsEventStatus_eIgnore;

  // Determine if this is the correct menu to handle the event
  MenuRef selectedMenuHandle = (MenuRef)aMenuEvent.mCommand;

  // at this point, the carbon event handler was installed so there
  // must be a carbon MenuRef to be had
  if (GetCarbonMenuRef(mMacMenu) == selectedMenuHandle) {
    if (mIsHelpMenu && mConstructed) {
      RemoveAll();
      mConstructed = false;
      SetRebuild(PR_TRUE);
    }

    // Open the node.
    mMenuContent->SetAttr(kNameSpaceID_None, nsWidgetAtoms::open, NS_LITERAL_STRING("true"), PR_TRUE);

    // Fire our oncreate handler. If we're told to stop, don't build the menu at all
    PRBool keepProcessing = OnCreate();

    if (!mIsHelpMenu && !mNeedsRebuild || !keepProcessing)
      return nsEventStatus_eConsumeNoDefault;

    if (!mConstructed || mNeedsRebuild) {
      if (mNeedsRebuild)
        RemoveAll();

      nsCOMPtr<nsIDocShell> docShell = do_QueryReferent(mDocShellWeakRef);
      if (!docShell) {
        NS_ERROR("No doc shell");
        return nsEventStatus_eConsumeNoDefault;
      }

      if (mIsHelpMenu) {
        HelpMenuConstruct(aMenuEvent, nsnull, nsnull, docShell);
        mConstructed = true;
      } else {
        MenuConstruct(aMenuEvent, nsnull, nsnull, docShell);
        mConstructed = true;
      }
    }

    OnCreated();  // Now that it's built, fire the popupShown event.

    eventStatus = nsEventStatus_eConsumeNoDefault;  
  }
  else {
    // Make sure none of our submenus are the ones that should be handling this
    PRUint32    numItems;
    mMenuItemsArray.Count(&numItems);
    for (PRUint32 i = numItems; i > 0; i--) {
      nsCOMPtr<nsISupports>     menuSupports = getter_AddRefs(mMenuItemsArray.ElementAt(i - 1));    
      nsCOMPtr<nsIMenu>         submenu = do_QueryInterface(menuSupports);
      nsCOMPtr<nsIMenuListener> menuListener = do_QueryInterface(submenu);
      if (menuListener) {
        eventStatus = menuListener->MenuSelected(aMenuEvent);
        if (nsEventStatus_eIgnore != eventStatus)
          return eventStatus;
      }  
    }
  }

  return eventStatus;
}


nsEventStatus nsMenuX::MenuDeselected(const nsMenuEvent & aMenuEvent)
{
  // Destroy the menu
  if (mConstructed) {
    MenuDestruct(aMenuEvent);
    mConstructed = false;
  }
  return nsEventStatus_eIgnore;
}


nsEventStatus nsMenuX::MenuConstruct(
    const nsMenuEvent & aMenuEvent,
    nsIWidget         * aParentWindow, 
    void              * /* menuNode */,
    void              * aDocShell)
{
  mConstructed = false;
  gConstructingMenu = PR_TRUE;
  
  // reset destroy handler flag so that we'll know to fire it next time this menu goes away.
  mDestroyHandlerCalled = PR_FALSE;
  
  //printf("nsMenuX::MenuConstruct called for %s = %d \n", NS_LossyConvertUCS2toASCII(mLabel).get(), mMacMenu);
  // Begin menuitem inner loop
  
  // Retrieve our menupopup.
  nsCOMPtr<nsIContent> menuPopup;
  GetMenuPopupContent(getter_AddRefs(menuPopup));
  if (!menuPopup)
    return nsEventStatus_eIgnore;
      
  // Iterate over the kids
  PRUint32 count = menuPopup->GetChildCount();
  for (PRUint32 i = 0; i < count; ++i) {
    nsIContent *child = menuPopup->GetChildAt(i);
    if (child) {
      // depending on the type, create a menu item, separator, or submenu
      nsIAtom *tag = child->Tag();
      if (tag == nsWidgetAtoms::menuitem)
        LoadMenuItem(this, child);
      else if (tag == nsWidgetAtoms::menuseparator)
        LoadSeparator(child);
      else if (tag == nsWidgetAtoms::menu)
        LoadSubMenu(this, child);
    }
  } // for each menu item
  
  gConstructingMenu = PR_FALSE;
  mNeedsRebuild = PR_FALSE;
  // printf("Done building, mMenuItemVoidArray.Count() = %d \n", mMenuItemVoidArray.Count());
  
  return nsEventStatus_eIgnore;
}


nsEventStatus nsMenuX::HelpMenuConstruct(
    const nsMenuEvent & aMenuEvent,
    nsIWidget         * aParentWindow, 
    void              * /* menuNode */,
    void              * aDocShell)
{ 
  int i, numHelpItems = [mMacMenu numberOfItems];
  for (i = 0; i < numHelpItems; i++)
    mMenuItemsArray.AppendElement(&gDummyMenuItemX);
     
  // Retrieve our menupopup.
  nsCOMPtr<nsIContent> menuPopup;
  GetMenuPopupContent(getter_AddRefs(menuPopup));
  if (!menuPopup)
    return nsEventStatus_eIgnore;
      
  // Iterate over the kids
  PRUint32 count = menuPopup->GetChildCount();
  for (PRUint32 i = 0; i < count; ++i) {
    nsIContent *child = menuPopup->GetChildAt(i);
    if (child) {      
      // depending on the type, create a menu item, separator, or submenu
      nsIAtom *tag = child->Tag();
      if (tag == nsWidgetAtoms::menuitem)
        LoadMenuItem(this, child);
      else if (tag == nsWidgetAtoms::menuseparator)
        LoadSeparator(child);
      else if (tag == nsWidgetAtoms::menu)
        LoadSubMenu(this, child);
    }   
  } // for each menu item
  
  // printf("Done building, mMenuItemVoidArray.Count() = %d \n", mMenuItemVoidArray.Count());
             
  return nsEventStatus_eIgnore;
}


nsEventStatus nsMenuX::MenuDestruct(const nsMenuEvent & aMenuEvent)
{
  // printf("nsMenuX::MenuDestruct() called for %s \n", NS_LossyConvertUCS2toASCII(mLabel).get());
  
  // Fire our ondestroy handler. If we're told to stop, don't destroy the menu
  PRBool keepProcessing = OnDestroy();
  if (keepProcessing) {
    if (mNeedsRebuild)
        mConstructed = false;
    // Close the node.
    mMenuContent->UnsetAttr(kNameSpaceID_None, nsWidgetAtoms::open, PR_TRUE);
    OnDestroyed();
  }
  return nsEventStatus_eIgnore;
}


nsEventStatus nsMenuX::CheckRebuild(PRBool & aNeedsRebuild)
{
  aNeedsRebuild = PR_TRUE;
  return nsEventStatus_eIgnore;
}


nsEventStatus nsMenuX::SetRebuild(PRBool aNeedsRebuild)
{
  if (!gConstructingMenu) {
    mNeedsRebuild = aNeedsRebuild;
  }
  return nsEventStatus_eIgnore;
}


NS_IMETHODIMP nsMenuX::SetEnabled(PRBool aIsEnabled)
{
  mIsEnabled = aIsEnabled;
  return NS_OK;
}


NS_IMETHODIMP nsMenuX::GetEnabled(PRBool* aIsEnabled)
{
  NS_ENSURE_ARG_POINTER(aIsEnabled);
  *aIsEnabled = mIsEnabled;
  return NS_OK;
}


NS_IMETHODIMP nsMenuX::IsHelpMenu(PRBool* aIsHelpMenu)
{
  NS_ENSURE_ARG_POINTER(aIsHelpMenu);
  *aIsHelpMenu = mIsHelpMenu;
  return NS_OK;
}


NS_IMETHODIMP nsMenuX::GetMenuContent(nsIContent ** aMenuContent)
{
  NS_ENSURE_ARG_POINTER(aMenuContent);
  NS_IF_ADDREF(*aMenuContent = mMenuContent);
  return NS_OK;
}


NSMenu* nsMenuX::CreateMenuWithGeckoString(nsString& menuTitle)
{
  NSString* title = [NSString stringWithCharacters:(UniChar*)menuTitle.get() length:menuTitle.Length()];
  NSMenu* myMenu = [[NSMenu alloc] initWithTitle:title];
  [myMenu setDelegate:mMenuDelegate];
  
  // we used to install Carbon event handlers here, but since NSMenu* doesn't
  // create its underlying MenuRef until just before display, we delay until
  // that happens. Now we install the event handlers when Cocoa notifies
  // us that a menu is about to display - see the Cocoa MenuDelegate class.
  
  return myMenu;
}


void nsMenuX::LoadMenuItem(nsIMenu* inParentMenu, nsIContent* inMenuItemContent)
{
  if (!inMenuItemContent)
    return;

  // if menu should be hidden, bail
  nsAutoString hidden;
  inMenuItemContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::hidden, hidden);
  if (hidden.EqualsLiteral("true"))
    return;

  // create nsMenuItem
  nsCOMPtr<nsIMenuItem> pnsMenuItem = do_CreateInstance(kMenuItemCID);
  if (pnsMenuItem) {
    nsAutoString disabled;
    nsAutoString checked;
    nsAutoString type;
    nsAutoString menuitemName;
    nsAutoString menuitemCmd;
    
    inMenuItemContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::disabled, disabled);
    inMenuItemContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::checked, checked);
    inMenuItemContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::type, type);
    inMenuItemContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::label, menuitemName);
    inMenuItemContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::command, menuitemCmd);

    // printf("menuitem %s \n", NS_LossyConvertUCS2toASCII(menuitemName).get());
              
    PRBool enabled = ! (disabled.EqualsLiteral("true"));
    
    nsIMenuItem::EMenuItemType itemType = nsIMenuItem::eRegular;
    if (type.EqualsLiteral("checkbox"))
      itemType = nsIMenuItem::eCheckbox;
    else if (type.EqualsLiteral("radio"))
      itemType = nsIMenuItem::eRadio;
      
    nsCOMPtr<nsIDocShell> docShell = do_QueryReferent(mDocShellWeakRef);
    if (!docShell)
      return;

    // Create the item.
    pnsMenuItem->Create(inParentMenu, menuitemName, PR_FALSE, itemType, 
                          enabled, mManager, docShell, inMenuItemContent);   

    // Set key shortcut and modifiers
    
    nsAutoString keyValue;
    inMenuItemContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::key, keyValue);

    // Try to find the key node. Get the document so we can do |GetElementByID|
    nsCOMPtr<nsIDOMDocument> domDocument =
      do_QueryInterface(inMenuItemContent->GetDocument());
    if (!domDocument)
      return;

    nsCOMPtr<nsIDOMElement> keyElement;
    if (!keyValue.IsEmpty())
      domDocument->GetElementById(keyValue, getter_AddRefs(keyElement));
    if (keyElement) {
      nsCOMPtr<nsIContent> keyContent (do_QueryInterface(keyElement));
      nsAutoString keyChar(NS_LITERAL_STRING(" "));
      keyContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::key, keyChar);
      if (!keyChar.EqualsLiteral(" ")) 
        pnsMenuItem->SetShortcutChar(keyChar);
        
      PRUint8 modifiers = knsMenuItemNoModifier;
      nsAutoString modifiersStr;
      keyContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::modifiers, modifiersStr);
      char* str = ToNewCString(modifiersStr);
      char* newStr;
      char* token = nsCRT::strtok(str, ", \t", &newStr);
      while (token != NULL) {
        if (PL_strcmp(token, "shift") == 0)
          modifiers |= knsMenuItemShiftModifier;
        else if (PL_strcmp(token, "alt") == 0) 
          modifiers |= knsMenuItemAltModifier;
        else if (PL_strcmp(token, "control") == 0) 
          modifiers |= knsMenuItemControlModifier;
        else if ((PL_strcmp(token, "accel") == 0) ||
                 (PL_strcmp(token, "meta") == 0)) {
          modifiers |= knsMenuItemCommandModifier;
        }

        token = nsCRT::strtok(newStr, ", \t", &newStr);
      }
      nsMemory::Free(str);

      pnsMenuItem->SetModifiers(modifiers);
    }

    if (checked.EqualsLiteral("true"))
      pnsMenuItem->SetChecked(PR_TRUE);
    else
      pnsMenuItem->SetChecked(PR_FALSE);
      
    nsCOMPtr<nsISupports> supports(do_QueryInterface(pnsMenuItem));
    inParentMenu->AddItem(supports); // Parent now owns menu item
  }
}


void 
nsMenuX::LoadSubMenu(nsIMenu * pParentMenu, nsIContent* inMenuItemContent)
{
  // if menu should be hidden, bail
  nsAutoString hidden; 
  inMenuItemContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::hidden, hidden);
  if (hidden.EqualsLiteral("true"))
    return;
  
  nsAutoString menuName; 
  inMenuItemContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::label, menuName);
  //printf("Creating Menu [%s] \n", NS_LossyConvertUCS2toASCII(menuName).get());

  // Create nsMenu
  nsCOMPtr<nsIMenu> pnsMenu(do_CreateInstance(kMenuCID));
  if (pnsMenu) {
    // Call Create
    nsCOMPtr<nsIDocShell> docShell = do_QueryReferent(mDocShellWeakRef);
    if (!docShell)
        return;
    nsCOMPtr<nsISupports> supports(do_QueryInterface(pParentMenu));
    pnsMenu->Create(supports, menuName, EmptyString(), mManager, docShell, inMenuItemContent);

    // set if it's enabled or disabled
    nsAutoString disabled;
    inMenuItemContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::disabled, disabled);
    if (disabled.EqualsLiteral("true"))
      pnsMenu->SetEnabled (PR_FALSE);
    else
      pnsMenu->SetEnabled (PR_TRUE);

    // Make nsMenu a child of parent nsMenu. The parent takes ownership
    nsCOMPtr<nsISupports> supports2(do_QueryInterface(pnsMenu));
    pParentMenu->AddItem(supports2);
  }     
}


void
nsMenuX::LoadSeparator(nsIContent* inMenuItemContent) 
{
  // if item should be hidden, bail
  nsAutoString hidden;
  inMenuItemContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::hidden, hidden);
  if (hidden.EqualsLiteral("true"))
    return;

  AddSeparator();
}



//
// OnCreate
//
// Fire our oncreate handler. Returns TRUE if we should keep processing the event,
// FALSE if the handler wants to stop the creation of the menu
//
PRBool
nsMenuX::OnCreate()
{
  nsEventStatus status = nsEventStatus_eIgnore;
  nsMouseEvent event(PR_TRUE, NS_XUL_POPUP_SHOWING, nsnull,
                     nsMouseEvent::eReal);
  
  nsCOMPtr<nsIContent> popupContent;
  GetMenuPopupContent(getter_AddRefs(popupContent));

  nsCOMPtr<nsIDocShell> docShell = do_QueryReferent(mDocShellWeakRef);
  if (!docShell) {
    NS_ERROR("No doc shell");
    return PR_FALSE;
  }
  nsCOMPtr<nsPresContext> presContext;
  MenuHelpersX::DocShellToPresContext(docShell, getter_AddRefs(presContext) );
  if (presContext) {
    nsresult rv = NS_OK;
    nsIContent* dispatchTo = popupContent ? popupContent : mMenuContent;
    rv = dispatchTo->HandleDOMEvent(presContext, &event, nsnull, NS_EVENT_FLAG_INIT, &status);
    if (NS_FAILED(rv) || status == nsEventStatus_eConsumeNoDefault)
      return PR_FALSE;
 }

  // the menu is going to show and the oncreate handler has executed. We
  // now need to walk our menu items, checking to see if any of them have
  // a command attribute. If so, several apptributes must potentially
  // be updated.
  if (popupContent) {
    nsCOMPtr<nsIDOMDocument> domDoc(do_QueryInterface(popupContent->GetDocument()));

    PRUint32 count = popupContent->GetChildCount();
    for (PRUint32 i = 0; i < count; i++) {
      nsIContent *grandChild = popupContent->GetChildAt(i);
      if (grandChild->Tag() == nsWidgetAtoms::menuitem) {
        // See if we have a command attribute.
        nsAutoString command;
        grandChild->GetAttr(kNameSpaceID_None, nsWidgetAtoms::command, command);
        if (!command.IsEmpty()) {
          // We do! Look it up in our document
          nsCOMPtr<nsIDOMElement> commandElt;
          domDoc->GetElementById(command, getter_AddRefs(commandElt));
          nsCOMPtr<nsIContent> commandContent(do_QueryInterface(commandElt));

          if (commandContent) {
            nsAutoString commandDisabled, menuDisabled;
            commandContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::disabled, commandDisabled);
            grandChild->GetAttr(kNameSpaceID_None, nsWidgetAtoms::disabled, menuDisabled);
            if (!commandDisabled.Equals(menuDisabled)) {
              // The menu's disabled state needs to be updated to match the command.
              if (commandDisabled.IsEmpty()) 
                grandChild->UnsetAttr(kNameSpaceID_None, nsWidgetAtoms::disabled, PR_TRUE);
              else grandChild->SetAttr(kNameSpaceID_None, nsWidgetAtoms::disabled, commandDisabled, PR_TRUE);
            }

            // The menu's value and checked states need to be updated to match the command.
            // Note that (unlike the disabled state) if the command has *no* value for either, we
            // assume the menu is supplying its own.
            nsAutoString commandChecked, menuChecked;
            commandContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::checked, commandChecked);
            grandChild->GetAttr(kNameSpaceID_None, nsWidgetAtoms::checked, menuChecked);
            if (!commandChecked.Equals(menuChecked)) {
              if (!commandChecked.IsEmpty()) 
                grandChild->SetAttr(kNameSpaceID_None, nsWidgetAtoms::checked, commandChecked, PR_TRUE);
            }

            nsAutoString commandValue, menuValue;
            commandContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::label, commandValue);
            grandChild->GetAttr(kNameSpaceID_None, nsWidgetAtoms::label, menuValue);
            if (!commandValue.Equals(menuValue)) {
              if (!commandValue.IsEmpty()) 
                grandChild->SetAttr(kNameSpaceID_None, nsWidgetAtoms::label, commandValue, PR_TRUE);
            }
          }
        }
      }
    }
  }
  
  return PR_TRUE;
}

PRBool
nsMenuX::OnCreated()
{
  nsEventStatus status = nsEventStatus_eIgnore;
  nsMouseEvent event(PR_TRUE, NS_XUL_POPUP_SHOWN, nsnull, nsMouseEvent::eReal);
  
  nsCOMPtr<nsIContent> popupContent;
  GetMenuPopupContent(getter_AddRefs(popupContent));

  nsCOMPtr<nsIDocShell> docShell = do_QueryReferent(mDocShellWeakRef);
  if (!docShell) {
    NS_ERROR("No doc shell");
    return PR_FALSE;
  }
  nsCOMPtr<nsPresContext> presContext;
  MenuHelpersX::DocShellToPresContext(docShell, getter_AddRefs(presContext));
  if (presContext) {
    nsresult rv = NS_OK;
    nsIContent* dispatchTo = popupContent ? popupContent : mMenuContent;
    rv = dispatchTo->HandleDOMEvent(presContext, &event, nsnull, NS_EVENT_FLAG_INIT, &status);
    if (NS_FAILED(rv) || status == nsEventStatus_eConsumeNoDefault)
      return PR_FALSE;
 }
  
  return PR_TRUE;
}

//
// OnDestroy
//
// Fire our ondestroy handler. Returns TRUE if we should keep processing the event,
// FALSE if the handler wants to stop the destruction of the menu
//
PRBool
nsMenuX::OnDestroy()
{
  if (mDestroyHandlerCalled)
    return PR_TRUE;

  nsEventStatus status = nsEventStatus_eIgnore;
  nsMouseEvent event(PR_TRUE, NS_XUL_POPUP_HIDING, nsnull,
                     nsMouseEvent::eReal);
  
  nsCOMPtr<nsIDocShell>  docShell = do_QueryReferent(mDocShellWeakRef);
  if (!docShell) {
    NS_WARNING("No doc shell so can't run the OnDestroy");
    return PR_FALSE;
  }

  nsCOMPtr<nsIContent> popupContent;
  GetMenuPopupContent(getter_AddRefs(popupContent));

  nsCOMPtr<nsPresContext> presContext;
  MenuHelpersX::DocShellToPresContext (docShell, getter_AddRefs(presContext) );
  if (presContext )  {
    nsresult rv = NS_OK;
    nsIContent* dispatchTo = popupContent ? popupContent : mMenuContent;
    rv = dispatchTo->HandleDOMEvent(presContext, &event, nsnull, NS_EVENT_FLAG_INIT, &status);

    mDestroyHandlerCalled = PR_TRUE;
    
    if (NS_FAILED(rv) || status == nsEventStatus_eConsumeNoDefault)
      return PR_FALSE;
  }
  return PR_TRUE;
}

PRBool
nsMenuX::OnDestroyed()
{
  nsEventStatus status = nsEventStatus_eIgnore;
  nsMouseEvent event(PR_TRUE, NS_XUL_POPUP_HIDDEN, nsnull,
                     nsMouseEvent::eReal);
  
  nsCOMPtr<nsIDocShell>  docShell = do_QueryReferent(mDocShellWeakRef);
  if (!docShell) {
    NS_WARNING("No doc shell so can't run the OnDestroy");
    return PR_FALSE;
  }

  nsCOMPtr<nsIContent> popupContent;
  GetMenuPopupContent(getter_AddRefs(popupContent));

  nsCOMPtr<nsPresContext> presContext;
  MenuHelpersX::DocShellToPresContext(docShell, getter_AddRefs(presContext));
  if (presContext)  {
    nsresult rv = NS_OK;
    nsIContent* dispatchTo = popupContent ? popupContent : mMenuContent;
    rv = dispatchTo->HandleDOMEvent(presContext, &event, nsnull, NS_EVENT_FLAG_INIT, &status);

    mDestroyHandlerCalled = PR_TRUE;
    
    if (NS_FAILED(rv) || status == nsEventStatus_eConsumeNoDefault)
      return PR_FALSE;
  }
  return PR_TRUE;
}
//
// GetMenuPopupContent
//
// Find the |menupopup| child in the |popup| representing this menu. It should be one
// of a very few children so we won't be iterating over a bazillion menu items to find
// it (so the strcmp won't kill us).
//
void
nsMenuX::GetMenuPopupContent(nsIContent** aResult)
{
  if (!aResult)
    return;
  *aResult = nsnull;
  
  nsresult rv;
  nsCOMPtr<nsIXBLService> xblService = do_GetService("@mozilla.org/xbl;1", &rv);
  if (!xblService)
    return;
  
  PRUint32 count = mMenuContent->GetChildCount();

  for (PRUint32 i = 0; i < count; i++) {
    PRInt32 dummy;
    nsIContent *child = mMenuContent->GetChildAt(i);
    nsCOMPtr<nsIAtom> tag;
    xblService->ResolveTag(child, &dummy, getter_AddRefs(tag));
    if (tag == nsWidgetAtoms::menupopup) {
      *aResult = child;
      NS_ADDREF(*aResult);
      return;
    }
  }

} // GetMenuPopupContent


//
// CountVisibleBefore
//
// Determines how many menus are visible among the siblings that are before me.
// It doesn't matter if I am visible. Note that this will always count the Apple
// menu, since we always put it in there.
//
nsresult 
nsMenuX::CountVisibleBefore (PRUint32* outVisibleBefore)
{
  NS_ASSERTION(outVisibleBefore, "bad index param");
  
  nsCOMPtr<nsIMenuBar> menubarParent = do_QueryInterface(mParent);
  if (!menubarParent) return NS_ERROR_FAILURE;

  PRUint32 numMenus = 0;
  menubarParent->GetMenuCount(numMenus);
  
  // Find this menu among the children of my parent menubar
  PRBool gotThisMenu = PR_FALSE;
  *outVisibleBefore = 1; // start at 1, the apple menu will always be there
  for (PRUint32 i = 0; i < numMenus; i++) {
    nsCOMPtr<nsIMenu> currMenu;
    menubarParent->GetMenuAt(i, *getter_AddRefs(currMenu));
    
    // we found ourselves, break out
    if (currMenu == NS_STATIC_CAST(nsIMenu*, this)) {
      gotThisMenu = PR_TRUE;
      break;
    }
      
    // check the current menu to see if it is visible (not hidden, not collapsed). If
    // it is, count it.
    if (currMenu) {
      nsCOMPtr<nsIContent> menuContent;
      currMenu->GetMenuContent(getter_AddRefs(menuContent));
      if (menuContent) {
        nsAutoString hiddenValue, collapsedValue;
        menuContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::hidden, hiddenValue);
        menuContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::collapsed, collapsedValue);
        if (menuContent->GetChildCount() > 0 ||
            !hiddenValue.EqualsLiteral("true") &&
            !collapsedValue.EqualsLiteral("true")) {
          ++(*outVisibleBefore);
        }
      }
    }
    
  } // for each menu

  return gotThisMenu ? NS_OK : NS_ERROR_FAILURE;
} // CountVisibleBefore


//
// nsIChangeObserver
//


NS_IMETHODIMP
nsMenuX::AttributeChanged(nsIDocument *aDocument, PRInt32 aNameSpaceID, nsIAtom *aAttribute)
{
  // ignore the |open| attribute, which is by far the most common
  if (gConstructingMenu || (aAttribute == nsWidgetAtoms::open))
    return NS_OK;
    
  nsCOMPtr<nsIMenuBar> menubarParent = do_QueryInterface(mParent);

  if (aAttribute == nsWidgetAtoms::disabled) {
    SetRebuild(PR_TRUE);
   
    nsAutoString valueString;
    mMenuContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::disabled, valueString);
    if (valueString.EqualsLiteral("true"))
      SetEnabled(PR_FALSE);
    else
      SetEnabled(PR_TRUE);
  } 
  else if (aAttribute == nsWidgetAtoms::label) {
    SetRebuild(PR_TRUE);
    
    mMenuContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::label, mLabel);

    // invalidate my parent. If we're a submenu parent, we have to rebuild
    // the parent menu in order for the changes to be picked up. If we're
    // a regular menu, just change the title and redraw the menubar.
    if (!menubarParent) {
      nsCOMPtr<nsIMenuListener> parentListener(do_QueryInterface(mParent));
      parentListener->SetRebuild(PR_TRUE);
    }
    else {
      // reuse the existing menu, to avoid rebuilding the root menu bar.
      NS_ASSERTION(mMacMenu != NULL, "nsMenuX::AttributeChanged: invalid menu handle.");
      RemoveAll();
      CFStringRef titleRef = ::CFStringCreateWithCharacters(kCFAllocatorDefault, (UniChar*)mLabel.get(), mLabel.Length());
      NS_ASSERTION(titleRef, "nsMenuX::AttributeChanged: CFStringCreateWithCharacters failed.");
      [mMacMenu setTitle:(NSString*)titleRef];
      ::CFRelease(titleRef);
    }
  }
  else if (aAttribute == nsWidgetAtoms::hidden || aAttribute == nsWidgetAtoms::collapsed) {
    SetRebuild(PR_TRUE);
    
    nsAutoString hiddenValue, collapsedValue;
    mMenuContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::hidden, hiddenValue);
    mMenuContent->GetAttr(kNameSpaceID_None, nsWidgetAtoms::collapsed, collapsedValue);
    
    if (hiddenValue.EqualsLiteral("true") || collapsedValue.EqualsLiteral("true")) {
      if (mVisible) {
        if (menubarParent) {
          PRUint32 indexToRemove = 0;
          if (NS_SUCCEEDED(CountVisibleBefore(&indexToRemove))) {
            indexToRemove++; // if there are N siblings before me, my index is N+1
            void *clientData = nsnull;
            menubarParent->GetNativeData(clientData);
            if (clientData) {
              NSMenu* menubar = reinterpret_cast<NSMenu*>(clientData);
              [menubar removeItemAtIndex:indexToRemove - 1];
              mVisible = PR_FALSE;
            }
          }
        } // if on the menubar
        else {
          // hide this submenu
          NS_ASSERTION(PR_FALSE, "nsMenuX::AttributeChanged: WRITE HIDE CODE FOR SUBMENU.");
        }
      } // if visible
      else
        NS_WARNING("You're hiding the menu twice, please stop");
    } // if told to hide menu
    else {
      if (!mVisible) {
        if (menubarParent) {
          PRUint32 insertAfter = 0;
          if (NS_SUCCEEDED(CountVisibleBefore(&insertAfter))) {
            void *clientData = nsnull;
            menubarParent->GetNativeData(clientData);
            if (clientData) {
              NSMenu* menubar = reinterpret_cast<NSMenu*>(clientData);
              // Shove this menu into its rightful place in the menubar. It doesn't matter
              // what title we pass to InsertMenuItem() because when we stuff the actual menu
              // handle in, the correct title goes with it.
              [menubar insertItemWithTitle:@"placeholder" action:NULL keyEquivalent:@"" atIndex:insertAfter - 1];
              [[menubar itemAtIndex:insertAfter] setSubmenu:mMacMenu];
              //::InsertMenuItem(menubar, "\pPlaceholder", insertAfter);
              //::SetMenuItemHierarchicalMenu(menubar, insertAfter + 1, mMacMenu);  // add 1 to get index of inserted item
              mVisible = PR_TRUE;
            }
          }
        } // if on menubar
        else {
          // show this submenu
          NS_ASSERTION(PR_FALSE, "nsMenuX::AttributeChanged: WRITE SHOW CODE FOR SUBMENU.");
        }
      } // if not visible
    } // if told to show menu
  }

  return NS_OK;
} // AttributeChanged


NS_IMETHODIMP
nsMenuX::ContentRemoved(nsIDocument *aDocument, nsIContent *aChild, PRInt32 aIndexInContainer)
{  
  if (gConstructingMenu)
    return NS_OK;

  SetRebuild(PR_TRUE);

  RemoveItem(aIndexInContainer);
  mManager->Unregister(aChild);

  return NS_OK;
} // ContentRemoved


NS_IMETHODIMP
nsMenuX::ContentInserted(nsIDocument *aDocument, nsIContent *aChild, PRInt32 aIndexInContainer)
{  
  if (gConstructingMenu)
    return NS_OK;

  SetRebuild(PR_TRUE);
  
  return NS_OK;
} // ContentInserted


//
// Carbon event support
//

static pascal OSStatus MyMenuEventHandler(EventHandlerCallRef myHandler, EventRef event, void* userData)
{
  OSStatus result = eventNotHandledErr;
  UInt32 kind = ::GetEventKind(event);
  if (kind == kEventMenuOpening || kind == kEventMenuClosed) {
    nsISupports* supports = reinterpret_cast<nsISupports*>(userData);
    nsCOMPtr<nsIMenuListener> listener(do_QueryInterface(supports));
    if (listener) {
      MenuRef menuRef;
      ::GetEventParameter(event, kEventParamDirectObject, typeMenuRef, NULL, sizeof(menuRef), NULL, &menuRef);
      nsMenuEvent menuEvent(PR_TRUE, NS_MENU_SELECTED, nsnull);
      menuEvent.time = PR_IntervalNow();
      menuEvent.mCommand = (PRUint32)menuRef;
      if (kind == kEventMenuOpening) {
        listener->MenuSelected(menuEvent);
      }
      else
        listener->MenuDeselected(menuEvent);
    }
  }
  return result;
}

static OSStatus InstallMyMenuEventHandler(MenuRef menuRef, void* userData, EventHandlerRef* outHandler)
{
  //XXXJOSH do we really need all these events?
  static EventTypeSpec eventList[] = {
  {kEventClassMenu, kEventMenuBeginTracking},
  {kEventClassMenu, kEventMenuEndTracking},
  {kEventClassMenu, kEventMenuChangeTrackingMode},
  {kEventClassMenu, kEventMenuOpening},
  {kEventClassMenu, kEventMenuClosed},
  {kEventClassMenu, kEventMenuTargetItem},
  {kEventClassMenu, kEventMenuMatchKey},
  {kEventClassMenu, kEventMenuEnableItems}};
  
  static EventHandlerUPP gMyMenuEventHandlerUPP = NewEventHandlerUPP(&MyMenuEventHandler);
  OSStatus status = ::InstallMenuEventHandler(menuRef, gMyMenuEventHandlerUPP,
                                   sizeof(eventList) / sizeof(EventTypeSpec), eventList,
                                   userData, outHandler);
  NS_ASSERTION(status == noErr,"Installing carbon menu events failed.");
  return status;
}

// #include <mach-o/dyld.h>
extern "C" MenuRef _NSGetCarbonMenu(NSMenu* aMenu);
static MenuRef GetCarbonMenuRef(NSMenu* aMenu)
{
  // we use a private API, so check for its existence and cache it (no static linking)
  //XXXJOSH I don't feel like debugging this now, so I'll leave it for later
  /*
  typedef MenuRef (*NSGetCarbonMenuPtr)(NSMenu* menu);
  static NSGetCarbonMenuPtr NSGetCarbonMenu = NULL;
  
  if (!NSGetCarbonMenu && NSIsSymbolNameDefined("_NSGetCarbonMenu"))
    NSGetCarbonMenu = (NSGetCarbonMenuPtr)NSAddressOfSymbol(NSLookupAndBindSymbol("_NSGetCarbonMenu"));
  
  if (NSGetCarbonMenu)
    return NSGetCarbonMenu(aMenu);
  else
    return NULL;
   */
  return _NSGetCarbonMenu(aMenu);
}


//
// MenuDelegate Cocoa class, receives events for the gecko menus
//


@implementation MenuDelegate

- (id)initWithGeckoMenu:(nsMenuX*)geckoMenu
{
  if ((self = [super init])) {
    mGeckoMenu = geckoMenu;
    mHaveInstalledCarbonEvents = FALSE;
  }
  return self;
}


// You can get a MenuRef from an NSMenu*, but not until it has been made visible
// or added to the main menu bar. Basically, Cocoa is attempting lazy loading,
// and that doesn't work for us. We don't need any carbon events until after the
// first time the menu is shown, so when that happens we install the carbon
// event handler. This works because at this point we can get a MenuRef without
// much trouble. This call is 10.3+, so this stuff won't work on 10.2.x or less.
- (void)menuNeedsUpdate:(NSMenu*)aMenu
{
  if (!mHaveInstalledCarbonEvents) {
    MenuRef myMenuRef = GetCarbonMenuRef(aMenu);
    if (myMenuRef) {
      InstallMyMenuEventHandler(myMenuRef, mGeckoMenu, nil); // can't be nil because we need to clean up
      mHaveInstalledCarbonEvents = TRUE;
    }
  }
}

// this gets called when some menu item in this menu get hit
- (IBAction)menuItemHit:(id)sender {
  NSLog(@"Your friendly Cocoa menu item delegat object would like to inform you that a menu item got hit\n");  
}


@end
