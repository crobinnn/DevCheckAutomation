# 📋 Device Check Automation  

An automated system for creating **Device Check Form & Documents**, seamlessly integrated with a **mobile app** developed with Flutter for barcode scanning. This solution simplifies the process of verifying and documenting device serial numbers (SN) and MAC addresses, reducing manual effort and ensuring accuracy.  

<br>

## 📱 Mobile App Integration  

The mobile application serves as a **barcode scanner**, allowing users to quickly capture device information by scanning:  
✅ **Serial Numbers (SN)**  
✅ **MAC Addresses**  

Each scanned entry is automatically linked to a stored **image of the device**, creating a structured dataset. A **server-side Python script** processes these entries, validating and storing them in a central repository.  

### 📌 Workflow  
1. **Scan a device** using the mobile app (barcode scanning for SN/MAC).  
2. **Store the entry** with its corresponding image.  
3. **Review & finalize** the dataset.  
4. **Generate a Device Check Document** by triggering the automation from the mobile app.  
5. **Receive a structured report** with device details, including SN, MAC, and images.  

<br>

## 🖥️ Manual Input Mode (Without Mobile App)  

For users without the mobile app, the system supports **manual entry** via a separate script.  
- Place a list of **device barcode photos in a designated folder**.  
- Run the **Python script**, which will scan the image for **SN/MAC for each image**.  
- The system **compiles all data** and **generates the final Device Check Form & Document**.  


